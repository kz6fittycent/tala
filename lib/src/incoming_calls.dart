import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log.dart';

enum CallState { pending, missed, joined }

class CallNote {
  const CallNote(this.id, this.token, this.name, this.isOneToOne);
  final int id;
  final String token;
  final String name;
  final bool isOneToOne;
}

abstract class CallSource {
  /// The user's call notifications, or null when nothing changed since the
  /// last check.
  Future<List<CallNote>?> callNotifications();
  Future<CallState> callState(String token);
  Future<void> dismissNotification(int id);
}

/// Spots calls meant for this user. A call notification can also mean a missed
/// call, so each one is confirmed with the server before ringing.
class IncomingCalls extends ChangeNotifier {
  IncomingCalls(this._source, {this.interval = const Duration(seconds: 4)});
  final CallSource _source;
  final Duration interval;

  Timer? _timer;
  bool _checking = false;
  bool _reportedError = false;
  List<CallNote> _notes = const [];
  final Set<int> _handled = {};

  CallNote? current;

  /// True during a call, when a second call shouldn't interrupt.
  bool suspended = false;

  void start() {
    _timer = Timer.periodic(interval, (_) => check());
    check();
  }

  @visibleForTesting
  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      _notes = await _source.callNotifications() ?? _notes;
      await _stopIfNoLongerRinging();
      if (current == null && !suspended) await _ringIfPending();
      _reportedError = false;
    } catch (e) {
      if (!_reportedError) log('incoming: check failed: $e');
      _reportedError = true;
    } finally {
      _checking = false;
    }
  }

  Future<void> _stopIfNoLongerRinging() async {
    final ring = current;
    if (ring == null) return;
    final gone = !_notes.any((n) => n.id == ring.id);
    final state = await _source.callState(ring.token);
    if (gone || state != CallState.pending) {
      log('incoming: stopped ringing ($state)');
      _handled.add(ring.id);
      current = null;
      notifyListeners();
    }
  }

  Future<void> _ringIfPending() async {
    for (final note in _notes) {
      if (_handled.contains(note.id)) continue;
      final state = await _source.callState(note.token);
      if (state == CallState.pending) {
        log('incoming: ringing for notification ${note.id}');
        current = note;
        notifyListeners();
        return;
      }
      log('incoming: notification ${note.id} is not ringing ($state)');
      _handled.add(note.id);
    }
  }

  /// Returns the call to join, and stops ringing.
  Future<CallNote?> accept() async {
    final ring = _take();
    if (ring != null) log('incoming: accepted');
    return ring;
  }

  Future<void> decline() async {
    final ring = _take();
    if (ring == null) return;
    log('incoming: declined');
    try {
      await _source.dismissNotification(ring.id);
    } catch (e) {
      log('incoming: dismiss failed: $e');
    }
  }

  CallNote? _take() {
    final ring = current;
    if (ring != null) _handled.add(ring.id);
    current = null;
    return ring;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
