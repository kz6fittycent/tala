import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'internal_signaling.dart';
import 'log.dart';
import 'ringer.dart';
import 'nc_api.dart';
import 'screen_share.dart';
import 'signaling.dart';

const _flagInCall = 1, _flagAudio = 2, _flagVideo = 4;

enum MeshRole { offer, wait, none }

/// What's still worth acting on after waiting for the camera. The other side
/// starts over every 10 seconds, so only its newest offer and that offer's
/// candidates still mean anything.
List<Map<String, dynamic>> freshMeshMessages(List<Map<String, dynamic>> held) {
  // A shared screen is a separate connection from the same person.
  (Object?, Object?) key(Map<String, dynamic> m) =>
      (m['from'], m['roomType'] ?? 'video');
  final newest = <(Object?, Object?), Object?>{};
  for (final m in held) {
    if (m['type'] == 'offer') newest[key(m)] = m['sid'];
  }
  return [
    for (final m in held)
      if (!newest.containsKey(key(m)) || m['sid'] == newest[key(m)]) m,
  ];
}

/// Without a media server, each pair connects directly, and the web client's
/// rule says who starts so both don't. Larger session ids call smaller ones,
/// unless only one side has anything to send. Comparison is by code unit, which
/// is what the web client's `<` does.
MeshRole meshRole({
  required String mine,
  required String theirs,
  required bool selfHasStreams,
  required bool theyHaveStreams,
}) {
  if (!selfHasStreams) return MeshRole.none;
  if (!theyHaveStreams || theirs.compareTo(mine) < 0) return MeshRole.offer;
  return MeshRole.wait;
}

class _Peer {
  _Peer(
    this.session,
    this.sid,
    this.pc, {
    this.roomType = 'video',
    this.broadcaster,
  });

  /// Whose screen a direct screen connection carries. The web client reads a
  /// screen offer without it as asking it to share its own.
  final String? broadcaster;
  final String session; // signaling session id; our own for the publisher
  final String sid;

  /// 'video' for camera and mic, 'screen' for a shared screen.
  final String roomType;
  final RTCPeerConnection pc;
  RTCVideoRenderer? renderer;
  RTCDataChannel? status;
  bool remoteSet = false;
  final List<RTCIceCandidate> queued = [];

  Future<void> addCandidate(RTCIceCandidate c) async {
    if (!remoteSet) {
      queued.add(c);
    } else {
      await pc.addCandidate(c);
    }
  }

  Future<void> flush() async {
    remoteSet = true;
    for (final c in queued) {
      await pc.addCandidate(c);
    }
    queued.clear();
  }
}

/// One call through the signaling server's SFU: we publish a single stream by
/// offering to our own session, and subscribe by asking for each publisher's.
/// What this client tells the server it's sending.
@visibleForTesting
int callFlags({required bool audio, required bool video}) =>
    _flagInCall | (audio ? _flagAudio : 0) | (video ? _flagVideo : 0);

/// Adds what's missing to the call's status.
@visibleForTesting
String mediaNote({
  required bool audio,
  required bool video,
  required String status,
}) {
  if (audio && video) return status;
  if (audio) return '$status (no camera)';
  if (video) return '$status (no mic)';
  return '$status (no camera or mic)';
}

class Call extends ChangeNotifier {
  /// The call in progress, so quitting from the tray can hang it up first.
  static Call? current;

  Call(this.api, this.room, {this.answering = false, this.openMedia});
  final NcApi api;
  final Room room;

  /// Joining a call that's ringing here, so someone is already in it even if
  /// the room list hasn't caught up.
  final bool answering;

  /// Replaces opening the real camera and mic, for developer checks.
  final Future<MediaStream?> Function()? openMedia;
  CallSignaling _sig = Signaling();

  /// No media server: each person connects directly to each other person.
  bool _mesh = false;
  bool _meshReady = false;
  final List<Map<String, dynamic>> _heldMessages = [];

  /// Handling takes awaits, and a candidate must not overtake its offer.
  Future<void> _meshQueue = Future.value();
  final Map<String, int> _meshUsers = {};
  final Set<String> _meshKnown = {};

  late SignalingSettings _settings;
  MediaStream? _local;
  _Peer? _publisher;
  RTCDataChannel? _status;
  final Map<String, _Peer> _subs = {};

  /// Screens other people are sharing, by their session. Receive-only.
  final Map<String, _Peer> _screens = {};

  /// The user's own screen: the capture, and where it goes. Through a media
  /// server it's published once and the server offers it to each person
  /// ([_screenSentTo]); without one, each person gets a connection
  /// ([_sharing]).
  ScreenCapture? _capture;
  _Peer? _screenPublisher;
  bool _screenPublished = false;
  final Set<String> _screenSentTo = {};
  final Map<String, _Peer> _sharing = {};

  /// Everyone else in the call, through a media server.
  final Set<String> _inCall = {};
  final Map<String, Timer> _offerRetry = {};
  bool _ended = false;
  bool _joinedRoom = false;
  bool _joinedCall = false;
  final Ringback _ringback = Ringback();
  bool _otherArrived = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  String state = 'Starting';
  bool micOn = true;
  bool camOn = true;

  /// The system's picker is open.
  bool choosingScreen = false;

  /// The user's screen is going out to the call.
  bool get sharingScreen => _capture != null && !choosingScreen;

  List<RTCVideoRenderer> get remotes => [
    for (final p in _subs.values)
      if (p.renderer != null) p.renderer!,
  ];

  List<RTCVideoRenderer> get screens => [
    for (final p in _screens.values)
      if (p.renderer != null) p.renderer!,
  ];

  void _state(String s) {
    state = s;
    log('call: $s');
    notifyListeners();
  }

  String _newSid() =>
      '${DateTime.now().millisecondsSinceEpoch}'
      '${Random().nextInt(1 << 32)}';

  Future<void> start() async {
    current = this;
    Future<MediaStream?>? media;
    try {
      log(
        'call: starting, room type ${room.type}, '
        'call already active: ${room.hasCall}',
      );
      await localRenderer.initialize();
      _settings = await api.signalingSettings(room.token);
      _mesh = _settings.server.isEmpty;
      if (_mesh && room.isFederated) {
        throw StateError(
          'Calls in conversations hosted on another server '
          'need a server with Nextcloud\'s High Performance Backend.',
        );
      }
      // The camera can take many seconds to open, and the other side shouldn't
      // wait for it to ring. Announcing the streams up front is safe: the
      // signaling server holds a stream request until the publisher appears
      // (10s by default), and the web and iOS clients keep asking after that.
      media = (openMedia ?? _openMedia)();
      _state('Joining');
      final ncSession = await api.joinRoom(room.token);
      _joinedRoom = true;
      if (_ended) {
        await _discard(media);
        return;
      }
      if (_mesh) {
        log('call: using internal signaling');
        final internal = InternalSignaling(api, room.token, ncSession);
        internal
          ..onMessage = _onMeshMessage
          ..onUsers = _onMeshUsers
          ..onStopped = (reason) {
            if (!_ended) _state(reason);
          };
        _sig = internal;
        internal.start();
      } else {
        final external = Signaling();
        _sig = external;
        external
          ..onMessage = _onMessage
          ..onEvent = _onEvent
          ..onClosed = () {
            if (!_ended) _state('Signaling connection lost');
          };
        await external.connect(api, _settings);
        if (!external.features.contains('mcu')) {
          log('call: server hello did not list mcu');
        }
        final federation = _settings.federationJoin;
        if (federation != null && !external.features.contains('federation')) {
          throw StateError(
            'This server\'s signaling server can\'t join calls '
            'hosted on another server. It may need updating.',
          );
        }
        await external.joinRoom(room.token, ncSession, federation: federation);
      }
      await api.joinCall(room.token, callFlags(audio: true, video: true));
      _joinedCall = true;
      // Nobody was in the call and nobody has arrived, so they're being rung.
      if (!room.hasCall && !answering && !_otherArrived && !_ended) {
        _ringback.start();
      }
      if (_subs.isEmpty) _state('In call, opening camera and mic');

      final local = await media;
      if (_ended) {
        await _discard(Future.value(local));
        return;
      }
      await _useMedia(local);
    } catch (e) {
      _ringback.stop();
      // Once it's in use, hanging up releases it.
      if (media != null && _local == null) unawaited(_discard(media));
      _state('Failed: $e');
    }
  }

  /// Never throws: a call can go on without a camera or mic, receive-only.
  Future<MediaStream?> _openMedia() async {
    try {
      return await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'width': 1280, 'height': 720, 'frameRate': 30},
      });
    } catch (e) {
      log('call: camera and mic failed: $e');
      return null;
    }
  }

  Future<void> _discard(Future<MediaStream?> media) async {
    final stream = await media;
    if (stream == null) return;
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  Future<void> _useMedia(MediaStream? stream) async {
    final audio = stream?.getAudioTracks().isNotEmpty ?? false;
    final video = stream?.getVideoTracks().isNotEmpty ?? false;
    log('call: media ready, audio: $audio, video: $video');
    if (!audio || !video) {
      // Others were told to expect both. A failure here must not end the call.
      try {
        await api.updateCallFlags(
          room.token,
          callFlags(audio: audio, video: video),
        );
      } catch (e) {
        log('call: updating call flags failed: $e');
      }
    }
    if (audio || video) {
      _local = stream;
      for (final t in stream!.getAudioTracks()) {
        t.enabled = micOn;
      }
      for (final t in stream.getVideoTracks()) {
        t.enabled = camOn;
      }
      localRenderer.srcObject = stream;
      if (!_mesh) await _publish();
    } else {
      await _discard(Future.value(stream));
    }
    if (_mesh) await _startMesh();
    final others = _subs.isEmpty
        ? 'In call, waiting for others'
        : 'In call with ${_subs.length} other(s)';
    _state(mediaNote(audio: audio, video: video, status: others));
  }

  Future<RTCPeerConnection> _newPc() => createPeerConnection({
    'iceServers': _settings.iceServers,
    'sdpSemantics': 'unified-plan',
  });

  Map<String, dynamic> _base(_Peer p, String type) => {
    'to': p.session,
    'type': type,
    'sid': p.sid,
    'roomType': p.roomType,
    'broadcaster': ?p.broadcaster,
  };

  void _wireIce(_Peer p, String label) {
    p.pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _sig.send(p.session, {
        ..._base(p, 'candidate'),
        'payload': {
          'type': 'candidate',
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        },
      });
    };
    p.pc.onConnectionState = (s) => log('$label: ${s.name}');
  }

  Future<void> _publish() async {
    final pc = await _newPc();
    final p = _publisher = _Peer(_sig.sessionId!, _newSid(), pc);
    _wireIce(p, 'publisher');
    for (final t in _local!.getTracks()) {
      await pc.addTrack(t, _local!);
    }
    _status = await pc.createDataChannel('status', RTCDataChannelInit());
    _status!.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) _sendStatus();
    };
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    _sig.send(p.session, {
      ..._base(p, 'offer'),
      'payload': {'type': 'offer', 'sdp': offer.sdp, 'nick': api.creds.user},
    });
    log('publisher: offer sent');
  }

  void _sendStatus() {
    void send(String type) {
      final message = RTCDataChannelMessage(jsonEncode({'type': type}));
      _status?.send(message);
      for (final p in _subs.values) {
        if (p.status?.state == RTCDataChannelState.RTCDataChannelOpen) {
          p.status!.send(message);
        }
      }
    }

    send(micOn ? 'audioOn' : 'audioOff');
    send(camOn ? 'videoOn' : 'videoOff');
  }

  void _onEvent(Map<String, dynamic> e) {
    final target = e['target'];
    if (target == 'participants' && e['type'] == 'update') {
      final update = e['update'] as Map?;
      if (update?['all'] == true && update?['incall'] == 0) {
        log('call: ended for everyone');
        _ringback.stop();
        for (final s in _subs.keys.toList()) {
          _dropSub(s);
        }
        for (final s in _screens.keys.toList()) {
          _dropScreen(s);
        }
        _inCall.clear();
        _screenSentTo.clear();
        return;
      }
      for (final u in (update?['users'] as List? ?? const [])) {
        final session = u['sessionId'] as String?;
        if (session == null || session == _sig.sessionId) continue;
        final flags = u['inCall'];
        final inCall = flags is int ? flags : (flags == true ? 1 : 0);
        if (inCall & _flagInCall != 0) {
          _otherArrived = true;
          _ringback.stop();
          _inCall.add(session);
          _sendScreenTo(session);
        }
        if (inCall & _flagInCall == 0) {
          _leftCall(session);
        } else if (inCall & (_flagAudio | _flagVideo) != 0 &&
            !_subs.containsKey(session)) {
          _requestOffer(session);
        }
      }
    } else if (target == 'room' && e['type'] == 'leave') {
      for (final s in (e['leave'] as List? ?? const [])) {
        _leftCall(s as String);
      }
    }
  }

  void _leftCall(String session) {
    _inCall.remove(session);
    // Offered again if they come back.
    _screenSentTo.remove(session);
    _dropSub(session);
  }

  /// A publisher may still be connecting when we first ask, so keep asking
  /// until its offer arrives.
  void _requestOffer(String session) {
    if (_ended || _offerRetry.containsKey(session)) return;
    var tries = 0;
    void ask() =>
        _sig.send(session, {'type': 'requestoffer', 'roomType': 'video'});
    log('subscriber: requesting a stream (${session.hashCode})');
    ask();
    _offerRetry[session] = Timer.periodic(const Duration(seconds: 3), (t) {
      if (++tries >= 10) {
        log('subscriber: gave up asking (${session.hashCode})');
        t.cancel();
        _offerRetry.remove(session);
      } else {
        ask();
      }
    });
  }

  Future<void> _onMessage(Map<String, dynamic> m) async {
    try {
      final data = (m['data'] as Map?)?.cast<String, dynamic>();
      if (data == null) return;
      final from = (m['sender']?['sessionid'] ?? data['from']) as String?;
      final payload = (data['payload'] as Map?)?.cast<String, dynamic>();
      final roomType = data['roomType'];
      switch (data['type']) {
        case 'answer':
          final screen = _screenPublisher;
          final forScreen =
              screen != null &&
              (data['sid'] == screen.sid ||
                  (data['sid'] == null && roomType == 'screen'));
          final p = forScreen ? screen : _publisher;
          if (p == null || payload == null) return;
          await p.pc.setRemoteDescription(
            RTCSessionDescription(payload['sdp'], 'answer'),
          );
          await p.flush();
          if (forScreen) {
            log('screen publisher: answer applied');
            _screenPublished = true;
            _inCall.forEach(_sendScreenTo);
          } else {
            log('publisher: answer applied');
          }
        case 'offer':
          if (from == null || payload == null) return;
          final sid = data['sid'] as String;
          final sdp = payload['sdp'] as String;
          if (roomType == 'screen') return await _watchScreen(from, sid, sdp);
          if (roomType != 'video') {
            log('subscriber: ignoring $roomType stream');
            return;
          }
          await _subscribe(from, sid, sdp);
        case 'unshareScreen':
          if (from != null) await _dropScreen(from);
        case 'candidate':
          final c = payload?['candidate'] as Map?;
          if (c == null || c['candidate'] == null) return;
          final sid = data['sid'];
          final peer = from == _sig.sessionId
              ? (roomType == 'screen' ? _screenPublisher : _publisher)
              : roomType == 'screen'
              ? (_sharing[from]?.sid == sid ? _sharing[from] : _screens[from])
              : _subs[from];
          await peer?.addCandidate(
            RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
          );
        default:
          break;
      }
    } catch (e) {
      log('call: failed handling a message: $e');
    }
  }

  Future<void> _subscribe(String session, String sid, String sdp) async {
    _offerRetry.remove(session)?.cancel();
    await _dropSub(session);
    final pc = await _newPc();
    final p = _Peer(session, sid, pc);
    _subs[session] = p;
    _wireIce(p, 'subscriber');
    _wireRemote(p);
    if (_mesh) {
      _watchMeshPeer(p);
      pc.onDataChannel = (channel) {
        if (channel.label == 'status') _useStatusChannel(p, channel);
      };
    }
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await p.flush();
    // A direct connection carries both directions, unlike a media server's.
    if (_mesh) await _addLocalTracks(pc);
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);
    _sig.send(session, {
      ..._base(p, 'answer'),
      'payload': {'type': 'answer', 'sdp': answer.sdp, 'nick': api.creds.user},
    });
    log('subscriber: answer sent');
  }

  /// Someone is sharing their screen: answer, and show it until they stop.
  /// Their client offers it, both through a media server and directly.
  Future<void> _watchScreen(String session, String sid, String sdp) async {
    if (_ended) return;
    await _dropScreen(session);
    final pc = await _newPc();
    final p = _Peer(
      session,
      sid,
      pc,
      roomType: 'screen',
      broadcaster: _mesh ? session : null,
    );
    _screens[session] = p;
    _wireIce(p, 'screen');
    pc.onConnectionState = (s) {
      log('screen: ${s.name}');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
          identical(_screens[session], p)) {
        unawaited(_dropScreen(session));
      }
    };
    pc.onTrack = (ev) async {
      if (ev.track.kind != 'video' || ev.streams.isEmpty) return;
      if (!identical(_screens[session], p)) return;
      if (p.renderer == null) {
        final r = RTCVideoRenderer();
        await r.initialize();
        p.renderer = r;
      }
      p.renderer!.srcObject = ev.streams.first;
      log('screen: showing a shared screen');
      notifyListeners();
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await p.flush();
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);
    _sig.send(session, {
      ..._base(p, 'answer'),
      'payload': {'type': 'answer', 'sdp': answer.sdp, 'nick': api.creds.user},
    });
    log('screen: answer sent');
  }

  Future<void> _dropScreen(String session) async {
    final p = _screens.remove(session);
    if (p == null) return;
    log('screen: stopped');
    await p.renderer?.dispose();
    await p.pc.close();
    notifyListeners();
  }

  void _wireRemote(_Peer p) {
    p.pc.onTrack = (ev) async {
      log('subscriber: got ${ev.track.kind} track');
      if (ev.streams.isEmpty) return;
      if (p.renderer == null) {
        final r = RTCVideoRenderer();
        await r.initialize();
        p.renderer = r;
      }
      p.renderer!.srcObject = ev.streams.first;
      _state('In call with ${_subs.length} other(s)');
    };
  }

  Future<void> _addLocalTracks(RTCPeerConnection pc) async {
    final local = _local;
    if (local == null) return;
    for (final t in local.getTracks()) {
      await pc.addTrack(t, local);
    }
  }

  void _useStatusChannel(_Peer p, RTCDataChannel channel) {
    p.status = channel;
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) _sendStatus();
    };
  }

  /// Messages can arrive before the camera opens. A connection answered then
  /// wouldn't carry the user's video, so everything waits for [_startMesh].
  void _onMeshMessage(Map<String, dynamic> data) {
    if (_ended) return;
    if (!_meshReady) {
      _heldMessages.add(data);
      return;
    }
    _queueMeshMessage(data);
  }

  void _queueMeshMessage(Map<String, dynamic> data) {
    _meshQueue = _meshQueue.then((_) => _handleMeshMessage(data));
  }

  Future<void> _handleMeshMessage(Map<String, dynamic> data) async {
    if (_ended) return;
    final from = data['from'] as String?;
    final screen = data['roomType'] == 'screen';
    final sid = data['sid'];
    if (data['type'] == 'candidate' &&
        (screen
            ? sid != _screens[from]?.sid && sid != _sharing[from]?.sid
            : sid != _subs[from]?.sid)) {
      return;
    }
    if (data['type'] != 'answer') return _onMessage({'data': data});
    try {
      final payload = data['payload'];
      // An answer to an offer of the user's own screen, or of their camera.
      final p = screen ? _sharing[from] : _subs[from];
      if (p == null || payload is! Map || data['sid'] != p.sid) return;
      await p.pc.setRemoteDescription(
        RTCSessionDescription(payload['sdp'] as String, 'answer'),
      );
      await p.flush();
      log(screen ? 'screen peer: answer applied' : 'peer: answer applied');
    } catch (e) {
      log('call: failed handling an answer: $e');
    }
  }

  Future<void> _startMesh() async {
    _meshReady = true;
    final held = freshMeshMessages(_heldMessages);
    _heldMessages.clear();
    held.forEach(_queueMeshMessage);
    await _meshQueue;
    _syncMeshUsers();
  }

  void _onMeshUsers(List<SignalingUser> users) {
    if (_ended) return;
    _meshUsers
      ..clear()
      ..addEntries([
        for (final u in users)
          if (u.sessionId != _sig.sessionId && u.inCall & _flagInCall != 0)
            MapEntry(u.sessionId, u.inCall),
      ]);
    if (_meshUsers.isNotEmpty) {
      _otherArrived = true;
      _ringback.stop();
    }
    if (_meshReady) _syncMeshUsers();
  }

  /// Each person is acted on once when they arrive, as in the web client,
  /// which ignores flag changes from anyone it has already seen.
  void _syncMeshUsers() {
    for (final session in _meshKnown.toList()) {
      if (_meshUsers.containsKey(session)) continue;
      _meshKnown.remove(session);
      unawaited(_dropSharing(session));
      unawaited(_dropSub(session).then((_) => _noteMeshCount()));
    }
    for (final entry in _meshUsers.entries) {
      if (_meshKnown.add(entry.key)) {
        unawaited(_connectMeshPeer(entry.key));
        _sendScreenTo(entry.key);
      }
    }
  }

  void _noteMeshCount() {
    if (_ended) return;
    _state(
      _subs.isEmpty
          ? 'In call, waiting for others'
          : 'In call with ${_subs.length} other(s)',
    );
  }

  Future<void> _connectMeshPeer(String session) async {
    if (_ended || !_meshKnown.contains(session)) return;
    // Already answering their offer, so a second connection would only collide.
    if (_subs.containsKey(session)) return;
    final flags = _meshUsers[session] ?? 0;
    final role = meshRole(
      mine: _sig.sessionId!,
      theirs: session,
      selfHasStreams: _local != null,
      theyHaveStreams: flags & (_flagAudio | _flagVideo) != 0,
    );
    switch (role) {
      case MeshRole.offer:
        await _meshOffer(session);
      case MeshRole.wait:
        _awaitMeshOffer(session);
      case MeshRole.none:
        log('peer: nothing to send either way');
    }
  }

  /// If the other side thinks it's still connected it won't offer, so after 10s
  /// without a connection, start over from this side.
  void _awaitMeshOffer(String session) {
    if (_offerRetry.containsKey(session)) return;
    _offerRetry[session] = Timer.periodic(const Duration(seconds: 10), (_) {
      log('peer: no connection yet, offering (${session.hashCode})');
      unawaited(_meshOffer(session, keepRetrying: true));
    });
  }

  Future<void> _meshOffer(String session, {bool keepRetrying = false}) async {
    try {
      final retry = keepRetrying ? _offerRetry.remove(session) : null;
      await _dropSub(session);
      if (retry != null) _offerRetry[session] = retry;
      if (_ended || !_meshKnown.contains(session)) return;
      final pc = await _newPc();
      final p = _Peer(session, _newSid(), pc);
      _subs[session] = p;
      _wireIce(p, 'peer');
      _wireRemote(p);
      _watchMeshPeer(p);
      await _addLocalTracks(pc);
      final local = _local;
      // The other side may send what this side doesn't.
      if (local != null && local.getAudioTracks().isEmpty) {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      if (local != null && local.getVideoTracks().isEmpty) {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      _useStatusChannel(
        p,
        await pc.createDataChannel('status', RTCDataChannelInit()),
      );
      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);
      _sig.send(session, {
        ..._base(p, 'offer'),
        'payload': {'type': 'offer', 'sdp': offer.sdp, 'nick': api.creds.user},
      });
      log('peer: offer sent');
    } catch (e) {
      log('call: offering failed: $e');
    }
  }

  void _watchMeshPeer(_Peer p) {
    p.pc.onConnectionState = (s) {
      log('peer: ${s.name}');
      if (_ended || !identical(_subs[p.session], p)) return;
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _offerRetry.remove(p.session)?.cancel();
          _noteMeshCount();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // Whoever would have offered does so again, and the other side's
          // timer covers the case where they don't know it failed.
          unawaited(
            _dropSub(p.session).then((_) => _connectMeshPeer(p.session)),
          );
        default:
          break;
      }
    };
  }

  /// Bytes received and sent so far, for developer checks.
  Future<String> meshStats() async {
    final parts = <String>[];
    for (final p in _subs.values) {
      for (final report in await p.pc.getStats()) {
        final v = report.values;
        if (report.type == 'inbound-rtp') {
          parts.add('in ${v['kind'] ?? v['mediaType']} ${v['bytesReceived']}');
        } else if (report.type == 'outbound-rtp') {
          parts.add('out ${v['kind'] ?? v['mediaType']} ${v['bytesSent']}');
        }
      }
    }
    return parts.join(', ');
  }

  /// Opens the system's picker and shares what the user chooses. Returns a
  /// message to show if it didn't work; cancelling isn't a failure.
  Future<String?> shareScreen() async {
    if (_ended || _capture != null || _sig.sessionId == null) return null;
    final ScreenCapture capture;
    try {
      capture = await ScreenCapture.open();
    } catch (e) {
      log('screen share: couldn\'t start: ${e.runtimeType}');
      return 'Couldn\'t start sharing your screen.';
    }
    _capture = capture;
    choosingScreen = true;
    notifyListeners();
    final first = await capture.answer;
    // Hung up or stopped while the picker was open.
    if (!identical(_capture, capture)) return null;
    choosingScreen = false;
    if (first != ShareState.sharing) {
      _capture = null;
      notifyListeners();
      await capture.close();
      return first == ShareState.cancelled
          ? null
          : 'Couldn\'t share your screen.';
    }
    // Ended from the system: a closed window, or its own Stop.
    unawaited(
      capture.ended.then((_) {
        if (identical(_capture, capture)) unawaited(stopSharing());
      }),
    );
    notifyListeners();
    try {
      if (_mesh) {
        _meshKnown.forEach(_sendScreenTo);
      } else {
        await _publishScreen(capture.stream);
      }
    } catch (e) {
      log('screen share: sending failed: $e');
      await stopSharing();
      return 'Couldn\'t share your screen.';
    }
    return null;
  }

  Future<void> _publishScreen(MediaStream stream) async {
    final pc = await _newPc();
    final p = _screenPublisher = _Peer(
      _sig.sessionId!,
      _newSid(),
      pc,
      roomType: 'screen',
    );
    _wireIce(p, 'screen publisher');
    for (final t in stream.getVideoTracks()) {
      await pc.addTrack(t, stream);
    }
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    _sig.send(p.session, {
      ..._base(p, 'offer'),
      'payload': {'type': 'offer', 'sdp': offer.sdp, 'nick': api.creds.user},
    });
    log('screen publisher: offer sent');
  }

  /// Through a media server, asks it to offer the screen to [session], once
  /// it has the screen. Directly, offers it from here.
  void _sendScreenTo(String session) {
    if (!sharingScreen || _ended) return;
    if (_mesh) {
      if (!_sharing.containsKey(session)) unawaited(_offerScreen(session));
      return;
    }
    if (!_screenPublished || !_screenSentTo.add(session)) return;
    _sig.send(session, {'type': 'sendoffer', 'roomType': 'screen'});
    log('screen: asked the server to offer it (${session.hashCode})');
  }

  Future<void> _offerScreen(String session) async {
    final capture = _capture;
    if (capture == null) return;
    try {
      final pc = await _newPc();
      final p = _Peer(
        session,
        _newSid(),
        pc,
        roomType: 'screen',
        broadcaster: _sig.sessionId,
      );
      if (!identical(_capture, capture) || _sharing.containsKey(session)) {
        await pc.close();
        return;
      }
      _sharing[session] = p;
      _wireIce(p, 'screen peer');
      pc.onConnectionState = (s) {
        log('screen peer: ${s.name}');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
            identical(_sharing[session], p)) {
          unawaited(
            _dropSharing(session).then((_) {
              if (_meshKnown.contains(session)) _sendScreenTo(session);
            }),
          );
        }
      };
      for (final t in capture.stream.getVideoTracks()) {
        await pc.addTrack(t, capture.stream);
      }
      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);
      _sig.send(session, {
        ..._base(p, 'offer'),
        'payload': {'type': 'offer', 'sdp': offer.sdp, 'nick': api.creds.user},
      });
      log('screen peer: offer sent');
    } catch (e) {
      log('screen peer: offering failed: $e');
    }
  }

  Future<void> _dropSharing(String session) async {
    final p = _sharing.remove(session);
    await p?.pc.close();
  }

  /// Stops sharing and tells everyone, as the web client does.
  Future<void> stopSharing() async {
    final capture = _capture;
    if (capture == null) return;
    _capture = null;
    choosingScreen = false;
    notifyListeners();
    if (_screenPublisher case final p?) {
      // Through a media server, one message reaches the whole room.
      final sig = _sig;
      if (sig is Signaling) {
        sig.sendToRoom({'type': 'unshareScreen', 'roomType': 'screen'});
      }
      _screenPublisher = null;
      await p.pc.close();
    }
    _screenPublished = false;
    _screenSentTo.clear();
    for (final session in _sharing.keys.toList()) {
      final p = _sharing[session]!;
      _sig.send(session, _base(p, 'unshareScreen'));
      await _dropSharing(session);
    }
    await capture.close();
    log('screen share: stopped');
  }

  Future<void> _dropSub(String session) async {
    _offerRetry.remove(session)?.cancel();
    // Someone who leaves stops sharing too.
    await _dropScreen(session);
    final p = _subs.remove(session);
    if (p == null) return;
    await p.renderer?.dispose();
    await p.pc.close();
    notifyListeners();
  }

  void toggleMic() {
    micOn = !micOn;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = micOn;
    }
    _sendStatus();
    notifyListeners();
  }

  void toggleCam() {
    camOn = !camOn;
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = camOn;
    }
    _sendStatus();
    notifyListeners();
  }

  Future<void> hangUp() async {
    if (_ended) return;
    _ended = true;
    _ringback.stop();
    if (identical(current, this)) current = null;
    for (final t in _offerRetry.values) {
      t.cancel();
    }
    _offerRetry.clear();
    await stopSharing();
    for (final s in _subs.keys.toList()) {
      await _dropSub(s);
    }
    for (final s in _screens.keys.toList()) {
      await _dropScreen(s);
    }
    await _publisher?.pc.close();
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _local?.dispose();
    await localRenderer.dispose();
    try {
      if (_joinedCall) await api.leaveCall(room.token);
      if (_joinedRoom) await api.leaveRoom(room.token);
    } catch (e) {
      log('call: leaving failed: $e');
    }
    await _sig.close();
    log('call: hung up');
  }
}
