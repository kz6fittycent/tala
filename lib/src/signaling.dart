import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';
import 'nc_api.dart';

class SignalingError implements Exception {
  SignalingError(this.code, this.text);
  final String code;
  final String text;
  @override
  String toString() => 'signaling error $code: $text';
}

/// What a call needs from signaling, however it travels.
abstract class CallSignaling {
  String? get sessionId;
  set onMessage(void Function(Map<String, dynamic> message)? handler);
  void send(String recipientSession, Map<String, dynamic> data);
  Future<void> close();
}

/// Client for the external signaling server (protocol in strukturag's
/// nextcloud-spreed-signaling docs/standalone-signaling-api-v1.md).
class Signaling implements CallSignaling {
  WebSocket? _ws;
  int _nextId = 1;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  @override
  String? sessionId;
  List<String> features = const [];

  @override
  void Function(Map<String, dynamic> message)? onMessage;
  void Function(Map<String, dynamic> event)? onEvent;
  void Function()? onClosed;

  Future<void> connect(NcApi api, SignalingSettings s) async {
    final url = s.server
        .replaceAll(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'^http'), 'ws');
    _ws = await WebSocket.connect('$url/spreed')
      ..pingInterval = const Duration(seconds: 30);
    _ws!.listen(_receive, onDone: () {
      log('signaling: closed');
      onClosed?.call();
    }, onError: (Object e) => log('signaling: socket error $e'));

    final v2 = s.helloV2;
    final hello = await _request('hello', {
      'version': v2 != null ? '2.0' : '1.0',
      'auth': {
        'url': api.signalingBackendUrl,
        'params': v2 != null
            ? {'token': v2['token']}
            : {'userid': s.userId, 'ticket': s.ticket},
      },
    });
    final h = hello['hello'] as Map<String, dynamic>;
    sessionId = h['sessionid'] as String;
    features = ((h['server']?['features'] as List?) ?? const []).cast<String>();
    log('signaling: hello ok, version ${h['version']}, '
        'mcu=${features.contains('mcu')}');
  }

  Future<void> joinRoom(
    String token,
    String ncSession, {
    Map<String, dynamic>? federation,
  }) async {
    await _request('room', {
      'roomid': token,
      'sessionid': ncSession,
      'federation': ?federation,
    });
    log('signaling: joined room');
  }

  @override
  void send(String recipientSession, Map<String, dynamic> data) {
    _ws?.add(jsonEncode({
      'type': 'message',
      'message': {
        'recipient': {'type': 'session', 'sessionid': recipientSession},
        'data': data,
      },
    }));
  }

  /// To everyone in the room, such as a shared screen ending.
  void sendToRoom(Map<String, dynamic> data) {
    _ws?.add(jsonEncode({
      'type': 'message',
      'message': {
        'recipient': {'type': 'room'},
        'data': data,
      },
    }));
  }

  Future<Map<String, dynamic>> _request(String type, Map<String, dynamic> body) {
    final id = '${_nextId++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws!.add(jsonEncode({'id': id, 'type': type, type: body}));
    return c.future.timeout(const Duration(seconds: 15));
  }

  void _receive(dynamic raw) {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final id = m['id'] as String?;
    final type = m['type'] as String?;
    if (id != null && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      if (type == 'error') {
        c.completeError(SignalingError(
            '${m['error']?['code']}', '${m['error']?['message']}'));
      } else {
        c.complete(m);
      }
      return;
    }
    switch (type) {
      case 'message':
        onMessage?.call((m['message'] as Map).cast<String, dynamic>());
      case 'event':
        onEvent?.call((m['event'] as Map).cast<String, dynamic>());
      case 'error':
        log('signaling: error ${m['error']?['code']}: ${m['error']?['message']}');
      case 'bye':
        log('signaling: bye');
      default:
        break;
    }
  }

  @override
  Future<void> close() async {
    await _ws?.close();
    _ws = null;
  }
}
