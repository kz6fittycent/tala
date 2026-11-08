import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'log.dart';

/// How a screen capture is going, as the system reports it.
enum ShareState { sharing, cancelled, stopped, failed }

/// The state in a "portalScreenCast" event from Tala's plugin patch, if the
/// event is about [streamId].
ShareState? shareStateOf(Map<String, dynamic> event, String streamId) {
  final m = event['portalScreenCast'];
  if (m is! Map || m['streamId'] != streamId) return null;
  return switch (m['state']) {
    'sharing' => ShareState.sharing,
    'cancelled' => ShareState.cancelled,
    'stopped' => ShareState.stopped,
    _ => ShareState.failed,
  };
}

/// One share of a screen or window, picked in the system's own dialog.
///
/// Tala's patch to flutter_webrtc runs the desktop portal itself (see
/// third_party/flutter_webrtc/TALA_PATCHES.md): one picker per share, and it
/// says when someone cancels or stops sharing from the system.
class ScreenCapture {
  ScreenCapture._(this.stream);

  /// Gets frames once [states] says sharing.
  final MediaStream stream;
  final Completer<ShareState> _answer = Completer();
  final Completer<ShareState> _end = Completer();
  StreamSubscription<Map<String, dynamic>>? _events;
  bool _closed = false;

  /// The picker's outcome: sharing, or why not. Cancelled if closed first.
  Future<ShareState> get answer => _answer.future;

  /// How a share that started ended, if the system ended it. Never completes
  /// if [close] comes first.
  Future<ShareState> get ended => _end.future;

  /// Shows the picker. The stream comes back at once, before any choice.
  static Future<ScreenCapture> open() async {
    // Listening first: the answer can't then arrive before anyone hears it.
    final held = <Map<String, dynamic>>[];
    ScreenCapture? capture;
    final events = FlutterWebRTCEventChannel.instance.handleEvents.stream
        .listen((e) => capture == null ? held.add(e) : capture._event(e));
    try {
      final r = await WebRTC.invokeMethod('getPortalDisplayMedia', {
        'constraints': {
          'video': {'cursor': 'always'},
        },
      });
      final stream = MediaStreamNative(r['streamId'] as String, 'local')
        ..setMediaTracks(r['audioTracks'] as List, r['videoTracks'] as List);
      final opened = capture = ScreenCapture._(stream).._events = events;
      held.forEach(opened._event);
      return opened;
    } catch (_) {
      await events.cancel();
      rethrow;
    }
  }

  void _event(Map<String, dynamic> e) {
    final state = shareStateOf(e, stream.id);
    if (state == null || _closed) return;
    log('screen share: ${state.name}');
    if (!_answer.isCompleted) {
      _answer.complete(state);
    } else if (!_end.isCompleted && state != ShareState.sharing) {
      _end.complete(state);
    }
  }

  /// Ends the share and closes the picker if it's still open.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_answer.isCompleted) _answer.complete(ShareState.cancelled);
    await _events?.cancel();
    try {
      await WebRTC.invokeMethod('stopPortalDisplayMedia', {
        'streamId': stream.id,
      });
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    } catch (e) {
      log('screen share: closing failed: ${e.runtimeType}');
    }
  }
}
