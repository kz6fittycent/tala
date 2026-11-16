import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'chat.dart' show ApiException;
import 'internal_signaling.dart';
import 'log.dart';
import 'nc_api.dart';
import 'signaling.dart';

/// Someone else's session in the conversation, as signaling reports it.
class TypingPeer {
  const TypingPeer(this.signalingId, this.roomSessionId,
      {this.userId, this.name});

  /// Where messages go. The same as [roomSessionId] without an HPB.
  final String signalingId;

  /// Nextcloud's session id, as in the participant list.
  final String roomSessionId;
  final String? userId;

  /// From the HPB's join event; looked up otherwise.
  final String? name;
}

/// "Maya is typing…" and so on; null when nobody is.
String? typingLine(List<String> names) {
  switch (names.length) {
    case 0:
      return null;
    case 1:
      return '${names[0]} is typing…';
    case 2:
      return '${names[0]} and ${names[1]} are typing…';
    case 3:
      return '${names[0]}, ${names[1]} and ${names[2]} are typing…';
    default:
      final others = names.length - 2;
      return '${names[0]}, ${names[1]} and $others others are typing…';
  }
}

/// What a typing session needs from a signaling connection.
abstract class TypingLink {
  /// Our own session as others address it.
  String? get sessionId;
  void send(String to, Map<String, dynamic> data);
  Future<void> close();
}

/// Shows who else is typing in one conversation and tells them when the user
/// is, as Talk's web client does: `startedTyping` and `stoppedTyping` to every
/// other session (spreed's docs/signaling-messages.md, "Typing").
///
/// Typing travels over signaling, which needs a session in the conversation.
/// While a user has one, the server sends them no notifications for ordinary
/// messages there, on any device. So the session is held only while [active]:
/// the window has focus with this conversation open. It's a separate session
/// from a call's, with its own cookies, so neither can end the other.
class TypingSession extends ChangeNotifier {
  TypingSession(this.api, this.room, {this.connect});

  final NcApi? api;
  final Room room;

  /// Opens the connection; tests replace it. Calls back with what arrives.
  final Future<TypingLink?> Function(TypingSession session)? connect;

  /// How long after joining is wanted before it happens, so a quick switch
  /// through windows doesn't join and leave at once.
  static const joinDelay = Duration(seconds: 1);

  /// Typing counts as stopped this long after the last change to the text.
  static const idleStop = Duration(seconds: 10);

  bool _active = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _joinTimer;
  Timer? _idleTimer;
  TypingLink? _link;
  Future<void> Function()? _leave;

  final Map<String, TypingPeer> _peers = {};
  final Set<String> _typing = {};
  bool _selfTyping = false;

  /// Names by Nextcloud session id and by user id, from the participant list.
  final Map<String, String> _namesBySession = {};
  final Map<String, String> _namesByUser = {};
  DateTime? _namesFetched;

  /// Who's typing now, in the order they started.
  List<String> get names => [
        for (final id in _typing)
          if (_peers[id] case final peer?) _nameOf(peer),
      ];

  bool get connected => _link != null;

  bool get active => _active;
  set active(bool value) {
    if (value == _active || _disposed) return;
    _active = value;
    _joinTimer?.cancel();
    if (value) {
      _joinTimer = Timer(joinDelay, _join);
    } else {
      unawaited(_disconnect());
    }
  }

  /// From the composer: whether the user has text they're working on.
  void typing(bool now) {
    _idleTimer?.cancel();
    if (now) _idleTimer = Timer(idleStop, () => typing(false));
    if (now == _selfTyping) return;
    _selfTyping = now;
    for (final p in _peers.values) {
      _sendTyping(p.signalingId, now);
    }
  }

  void _sendTyping(String to, bool now) {
    _link?.send(to, {'to': to, 'type': now ? 'startedTyping' : 'stoppedTyping'});
  }

  Future<void> _join() async {
    if (!_active || _disposed || _link != null) return;
    final generation = ++_generation;
    try {
      final link = await (connect ?? _connectToServer)(this);
      if (link == null) return;
      if (generation != _generation || !_active || _disposed) {
        await link.close();
        await _leave?.call();
        _leave = null;
        return;
      }
      _link = link;
      log('typing: connected');
    } catch (e) {
      log('typing: could not connect: ${e is ApiException ? e.status : e}');
      await _leave?.call();
      _leave = null;
    }
  }

  Future<void> _disconnect() async {
    _generation++;
    final link = _link;
    final leave = _leave;
    _link = null;
    _leave = null;
    _selfTyping = false;
    _idleTimer?.cancel();
    final hadTyping = _typing.isNotEmpty;
    _peers.clear();
    _typing.clear();
    if (hadTyping && !_disposed) notifyListeners();
    try {
      await link?.close();
      await leave?.call();
    } catch (e) {
      log('typing: leaving failed: ${e is ApiException ? e.status : e}');
    }
  }

  Future<TypingLink?> _connectToServer(TypingSession _) async {
    final api = this.api;
    if (api == null || room.isFederated) return null;
    if (!await api.typingAllowed()) return null;
    final jar = <String, Cookie>{};
    final token = room.token;
    final ncSession = await api.joinRoom(token, jar: jar);
    _leave = () => api.leaveRoom(token, jar: jar);
    final settings = await api.signalingSettings(token);
    if (settings.server.isEmpty) {
      final internal = InternalSignaling(api, token, ncSession, jar: jar);
      internal
        ..onMessage = handleMessage
        ..onUsers = (users) {
          handleUsersInRoom(users, ownSession: ncSession);
        }
        ..onStopped = (_) {
          unawaited(_disconnect());
        };
      internal.start();
      return _InternalLink(internal);
    }
    final external = Signaling();
    external
      ..onMessage = handleMessage
      ..onEvent = handleEvent
      ..onClosed = () {
        if (_link != null) unawaited(_disconnect());
      };
    try {
      await external.connect(api, settings);
      await external.joinRoom(token, ncSession);
    } catch (_) {
      await external.close();
      rethrow;
    }
    return _ExternalLink(external);
  }

  /// A message from signaling: internal ones carry `from`, the HPB's a sender.
  @visibleForTesting
  void handleMessage(Map<String, dynamic> m) {
    final data = m['data'] is Map ? (m['data'] as Map) : m;
    final type = data['type'];
    if (type != 'startedTyping' && type != 'stoppedTyping') return;
    final from = (m['sender'] is Map ? m['sender']['sessionid'] : null) ??
        data['from'] ??
        m['from'];
    if (from is! String || !_peers.containsKey(from)) return;
    final changed = type == 'startedTyping' ? _typing.add(from) : _typing.remove(from);
    if (changed) {
      if (type == 'startedTyping') _lookUpNames(_peers[from]!);
      notifyListeners();
    }
  }

  /// The internal signaling's full list of sessions in the room.
  @visibleForTesting
  void handleUsersInRoom(List<SignalingUser> users, {required String ownSession}) {
    final now = <String, TypingPeer>{
      for (final u in users)
        if (u.sessionId != ownSession && !_isSelf(u.userId))
          u.sessionId: TypingPeer(u.sessionId, u.sessionId, userId: u.userId),
    };
    final joined = [
      for (final p in now.values)
        if (!_peers.containsKey(p.signalingId)) p,
    ];
    final left = [
      for (final id in _peers.keys)
        if (!now.containsKey(id)) id,
    ];
    _peers
      ..removeWhere((id, _) => !now.containsKey(id))
      ..addAll(now);
    _joined(joined);
    _left(left);
  }

  /// HPB room events: sessions joining and leaving.
  @visibleForTesting
  void handleEvent(Map<String, dynamic> e) {
    if (e['target'] != 'room') return;
    final own = _link?.sessionId;
    if (e['type'] == 'join') {
      final joined = <TypingPeer>[];
      for (final j in (e['join'] as List? ?? const [])) {
        if (j is! Map) continue;
        final sid = j['sessionid'];
        final userId = j['userid'] is String && j['userid'] != ''
            ? j['userid'] as String
            : null;
        if (sid is! String || sid == own || _isSelf(userId)) continue;
        final user = j['user'];
        final name = user is Map ? user['displayname'] : null;
        final peer = TypingPeer(
          sid,
          j['roomsessionid'] is String ? j['roomsessionid'] as String : sid,
          userId: userId,
          name: name is String && name.isNotEmpty ? name : null,
        );
        _peers[sid] = peer;
        joined.add(peer);
      }
      _joined(joined);
    } else if (e['type'] == 'leave') {
      final left = [
        for (final id in (e['leave'] as List? ?? const []))
          if (id is String && _peers.remove(id) != null) id,
      ];
      _left(left);
    }
  }

  bool _isSelf(String? userId) =>
      userId != null && room.selfId.isNotEmpty && userId == room.selfId;

  void _joined(List<TypingPeer> peers) {
    // Someone who arrives while the user is typing hears about it, as the web
    // client does.
    if (_selfTyping) {
      for (final p in peers) {
        _sendTyping(p.signalingId, true);
      }
    }
  }

  void _left(List<String> ids) {
    var changed = false;
    for (final id in ids) {
      changed |= _typing.remove(id);
    }
    if (changed) notifyListeners();
  }

  String _nameOf(TypingPeer p) =>
      p.name ??
      _namesBySession[p.roomSessionId] ??
      (p.userId != null ? _namesByUser[p.userId] : null) ??
      'Someone';

  /// The participant list names sessions; read when someone unnamed starts
  /// typing, at most every 30 seconds.
  void _lookUpNames(TypingPeer p) {
    final api = this.api;
    if (api == null || _nameOf(p) != 'Someone') return;
    final last = _namesFetched;
    if (last != null && DateTime.now().difference(last).inSeconds < 30) return;
    _namesFetched = DateTime.now();
    api.members(room.token).then((members) {
      for (final m in members) {
        for (final s in m.sessionIds) {
          _namesBySession[s] = m.displayName;
        }
        if (m.actorType == 'users') _namesByUser[m.actorId] = m.displayName;
      }
      if (!_disposed && _typing.isNotEmpty) notifyListeners();
    }, onError: (Object e) {
      log('typing: members failed: ${e is ApiException ? e.status : e}');
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _joinTimer?.cancel();
    _idleTimer?.cancel();
    unawaited(_disconnect());
    super.dispose();
  }
}

class _InternalLink implements TypingLink {
  _InternalLink(this._sig);
  final InternalSignaling _sig;
  @override
  String? get sessionId => _sig.sessionId;
  @override
  void send(String to, Map<String, dynamic> data) => _sig.send(to, data);
  @override
  Future<void> close() => _sig.close();
}

class _ExternalLink implements TypingLink {
  _ExternalLink(this._sig);
  final Signaling _sig;
  @override
  String? get sessionId => _sig.sessionId;
  @override
  void send(String to, Map<String, dynamic> data) => _sig.send(to, data);
  @override
  Future<void> close() => _sig.close();
}
