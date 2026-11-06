import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'log.dart';
import 'nc_api.dart';
import 'signaling.dart';

const _flagInCall = 1, _flagAudio = 2, _flagVideo = 4;

class _Peer {
  _Peer(this.session, this.sid, this.pc);
  final String session; // signaling session id; our own for the publisher
  final String sid;
  final RTCPeerConnection pc;
  RTCVideoRenderer? renderer;
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
class Call extends ChangeNotifier {
  /// The call in progress, so quitting from the tray can hang it up first.
  static Call? current;

  Call(this.api, this.room);
  final NcApi api;
  final Room room;
  final Signaling _sig = Signaling();

  late SignalingSettings _settings;
  MediaStream? _local;
  _Peer? _publisher;
  RTCDataChannel? _status;
  final Map<String, _Peer> _subs = {};
  final Map<String, Timer> _offerRetry = {};
  bool _ended = false;
  bool _joinedRoom = false;
  bool _joinedCall = false;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  String state = 'Starting';
  bool micOn = true;
  bool camOn = true;

  List<RTCVideoRenderer> get remotes =>
      [for (final p in _subs.values) if (p.renderer != null) p.renderer!];

  void _state(String s) {
    state = s;
    log('call: $s');
    notifyListeners();
  }

  String _newSid() => '${DateTime.now().millisecondsSinceEpoch}'
      '${Random().nextInt(1 << 32)}';

  Future<void> start() async {
    current = this;
    try {
      log('call: starting, room type ${room.type}, '
          'call already active: ${room.hasCall}');
      await localRenderer.initialize();
      _settings = await api.signalingSettings(room.token);
      if (_settings.server.isEmpty) {
        throw StateError('This server has no signaling server. '
            'The prototype only supports servers that have one.');
      }
      _state('Opening camera and mic');
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'width': 1280, 'height': 720, 'frameRate': 30},
      });
      if (_ended) {
        for (final t in _local!.getTracks()) {
          await t.stop();
        }
        await _local!.dispose();
        return;
      }
      localRenderer.srcObject = _local;

      _state('Joining');
      final ncSession = await api.joinRoom(room.token);
      _joinedRoom = true;
      if (_ended) return;
      _sig
        ..onMessage = _onMessage
        ..onEvent = _onEvent
        ..onClosed = () {
          if (!_ended) _state('Signaling connection lost');
        };
      await _sig.connect(api, _settings);
      if (!_sig.features.contains('mcu')) {
        log('call: server hello did not list mcu');
      }
      final federation = _settings.federationJoin;
      if (federation != null && !_sig.features.contains('federation')) {
        throw StateError('This server\'s signaling server can\'t join calls '
            'hosted on another server. It may need updating.');
      }
      await _sig.joinRoom(room.token, ncSession, federation: federation);
      await api.joinCall(room.token, _flagInCall | _flagAudio | _flagVideo);
      _joinedCall = true;
      await _publish();
      _state(_subs.isEmpty
          ? 'In call, waiting for others'
          : 'In call with ${_subs.length} other(s)');
    } catch (e) {
      _state('Failed: $e');
    }
  }

  Future<RTCPeerConnection> _newPc() => createPeerConnection({
        'iceServers': _settings.iceServers,
        'sdpSemantics': 'unified-plan',
      });

  Map<String, dynamic> _base(_Peer p, String type) => {
        'to': p.session,
        'type': type,
        'sid': p.sid,
        'roomType': 'video',
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
    void send(String type) =>
        _status?.send(RTCDataChannelMessage(jsonEncode({'type': type})));
    send(micOn ? 'audioOn' : 'audioOff');
    send(camOn ? 'videoOn' : 'videoOff');
  }

  void _onEvent(Map<String, dynamic> e) {
    final target = e['target'];
    if (target == 'participants' && e['type'] == 'update') {
      final update = e['update'] as Map?;
      if (update?['all'] == true && update?['incall'] == 0) {
        log('call: ended for everyone');
        for (final s in _subs.keys.toList()) {
          _dropSub(s);
        }
        return;
      }
      for (final u in (update?['users'] as List? ?? const [])) {
        final session = u['sessionId'] as String?;
        if (session == null || session == _sig.sessionId) continue;
        final flags = u['inCall'];
        final inCall = flags is int ? flags : (flags == true ? 1 : 0);
        if (inCall & _flagInCall == 0) {
          _dropSub(session);
        } else if (inCall & (_flagAudio | _flagVideo) != 0 &&
            !_subs.containsKey(session)) {
          _requestOffer(session);
        }
      }
    } else if (target == 'room' && e['type'] == 'leave') {
      for (final s in (e['leave'] as List? ?? const [])) {
        _dropSub(s as String);
      }
    }
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
          final p = _publisher;
          if (p == null || payload == null) return;
          await p.pc.setRemoteDescription(
              RTCSessionDescription(payload['sdp'], 'answer'));
          await p.flush();
          log('publisher: answer applied');
        case 'offer':
          if (from == null || payload == null) return;
          if (roomType != 'video') {
            log('subscriber: ignoring $roomType stream in the prototype');
            return;
          }
          await _subscribe(from, data['sid'] as String, payload['sdp'] as String);
        case 'candidate':
          final c = payload?['candidate'] as Map?;
          if (c == null || c['candidate'] == null) return;
          final peer = from == _sig.sessionId ? _publisher : _subs[from];
          await peer?.addCandidate(RTCIceCandidate(
              c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
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
    pc.onTrack = (ev) async {
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
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await p.flush();
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);
    _sig.send(session, {
      ..._base(p, 'answer'),
      'payload': {'type': 'answer', 'sdp': answer.sdp, 'nick': api.creds.user},
    });
    log('subscriber: answer sent');
  }

  Future<void> _dropSub(String session) async {
    _offerRetry.remove(session)?.cancel();
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
    if (identical(current, this)) current = null;
    for (final t in _offerRetry.values) {
      t.cancel();
    }
    _offerRetry.clear();
    for (final s in _subs.keys.toList()) {
      await _dropSub(s);
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
