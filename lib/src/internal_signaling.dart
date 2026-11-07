import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'chat.dart' show ApiException;
import 'log.dart';
import 'nc_api.dart';
import 'signaling.dart';

/// One session in the conversation, from a `usersInRoom` list.
class SignalingUser {
  const SignalingUser(this.sessionId, this.inCall);
  final String sessionId;
  final int inCall;
}

/// What the server's `usersInRoom` and `message` entries mean for a call. Parses
/// the list a long poll returns, ignoring anything it doesn't recognize.
void readPull(
  Object? data, {
  required void Function(Map<String, dynamic> message) onMessage,
  required void Function(List<SignalingUser> users) onUsers,
}) {
  if (data is! List) return;
  for (final entry in data) {
    if (entry is! Map) continue;
    final body = entry['data'];
    switch (entry['type']) {
      case 'message':
        final decoded = body is String ? jsonDecode(body) : body;
        if (decoded is Map) onMessage(decoded.cast<String, dynamic>());
      case 'usersInRoom':
        if (body is! List) continue;
        onUsers([
          for (final u in body)
            if (u is Map && u['sessionId'] is String)
              SignalingUser(
                u['sessionId'] as String,
                u['inCall'] is int
                    ? u['inCall'] as int
                    : (u['inCall'] == true ? 1 : 0),
              ),
        ]);
      default:
        break;
    }
  }
}

/// A brief server hiccup shouldn't hold up a call that's just starting, so the
/// first retries are quick, settling at the web client's every 10 seconds.
Duration pullRetryDelay(int failures) =>
    Duration(seconds: failures >= 5 ? 10 : 1 << (failures - 1));

/// Why signaling stopped for good, in words for the call screen.
String? pullFailureEnds(int? status) => switch (status) {
  409 => 'You joined this conversation somewhere else',
  403 || 404 => 'This conversation is no longer available',
  400 => 'This server stopped using internal signaling',
  _ => null,
};

/// Signaling through Nextcloud itself, for servers with no High Performance
/// Backend: messages go out by POST and arrive by long poll. See Talk's
/// docs/signaling-messages.md. The session is the one from joining the room.
class InternalSignaling implements CallSignaling {
  InternalSignaling(this._api, this._token, this.sessionId);

  static const _maxFailures = 30;

  final NcApi _api;
  final String _token;

  /// The long poll has its own client so hanging up can cut it off at once.
  final HttpClient _pullClient = HttpClient();

  @override
  final String? sessionId;

  @override
  void Function(Map<String, dynamic> message)? onMessage;
  void Function(List<SignalingUser> users)? onUsers;

  /// Signaling stopped for good, with the reason to show.
  void Function(String reason)? onStopped;

  bool _closed = false;
  int _failures = 0;
  final List<Map<String, dynamic>> _outgoing = [];
  bool _sending = false;

  void start() => unawaited(_pull());

  Future<void> _pull() async {
    while (!_closed) {
      try {
        final data = await _api.pullSignaling(_token, _pullClient);
        _failures = 0;
        if (_closed) return;
        readPull(
          data,
          onMessage: (m) => onMessage?.call(m),
          onUsers: (u) => onUsers?.call(u),
        );
      } catch (e) {
        if (_closed) return;
        final status = e is ApiException ? e.status : null;
        final reason = pullFailureEnds(status);
        if (reason != null) {
          log('signaling: long poll ended with $status');
          _closed = true;
          onStopped?.call(reason);
          return;
        }
        if (++_failures >= _maxFailures) {
          log('signaling: giving up after $_failures failed polls');
          _closed = true;
          onStopped?.call('Signaling connection lost');
          return;
        }
        log('signaling: long poll failed: $e');
        await Future<void>.delayed(pullRetryDelay(_failures));
      }
    }
  }

  @override
  void send(String recipientSession, Map<String, dynamic> data) {
    if (_closed) return;
    _outgoing.add({
      'ev': 'message',
      'fn': jsonEncode({'to': recipientSession, ...data}),
      'sessionId': sessionId,
    });
    unawaited(_flush());
  }

  /// One request at a time, so messages arrive in order, batching what built
  /// up meanwhile: a new connection produces a burst of ICE candidates.
  Future<void> _flush() async {
    if (_sending) return;
    _sending = true;
    try {
      var tries = 0;
      while (_outgoing.isNotEmpty && !_closed) {
        final batch = List.of(_outgoing);
        try {
          await _api.sendSignaling(_token, jsonEncode(batch));
          _outgoing.removeRange(0, batch.length);
          tries = 0;
        } catch (e) {
          log('signaling: sending failed: $e');
          if (++tries >= 3) {
            // Later messages may still help; the 10s re-offer recovers a peer.
            _outgoing.removeRange(0, batch.length);
            tries = 0;
          } else {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
      }
    } finally {
      _sending = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _pullClient.close(force: true);
  }
}
