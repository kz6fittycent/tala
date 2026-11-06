import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log.dart';

/// A snap can only reach the PulseAudio socket, and ships paplay for it.
@visibleForTesting
String ringPlayer(Map<String, String> environment) =>
    environment.containsKey('SNAP') ? 'paplay' : 'pw-play';

/// What a caller hears until someone answers, on the usual 2 on, 4 off cadence.
/// Stops by itself so a call nobody answers doesn't ring forever.
class Ringback {
  Ringback({Future<Process> Function()? launch, Duration? gap, Duration? limit})
    : _launch = launch ?? _play,
      _gap = gap ?? const Duration(seconds: 4),
      _limit = limit ?? const Duration(seconds: 60);

  final Future<Process> Function() _launch;
  final Duration _gap;
  final Duration _limit;
  Process? _player;
  Timer? _limitTimer;
  bool _started = false;
  bool _on = false;

  bool get isOn => _on;

  static Future<Process> _play() => Process.start(
    ringPlayer(Platform.environment),
    ['${File(Platform.resolvedExecutable).parent.path}'
        '/data/flutter_assets/assets/sounds/ringback.wav'],
  );

  /// Once per call: it doesn't start again after someone has answered and left.
  void start() {
    if (_started) return;
    _started = _on = true;
    _limitTimer = Timer(_limit, stop);
    unawaited(_loop());
  }

  void stop() {
    _on = false;
    _limitTimer?.cancel();
    _player?.kill();
    _player = null;
  }

  Future<void> _loop() async {
    while (_on) {
      try {
        final player = await _launch();
        if (!_on) {
          player.kill();
          return;
        }
        _player = player;
        await player.exitCode;
      } catch (e) {
        log('ringback: could not play sound: $e');
        _on = false;
        return;
      }
      if (_on) await Future<void>.delayed(_gap);
    }
  }
}

/// Linux-only for now: repeats the ring sound and shows a desktop notification.
/// Mac and Windows need their own version of this class.
class Ringer {
  Process? _player;
  bool _ringing = false;
  String? _notificationId;

  String get _sound => '${File(Platform.resolvedExecutable).parent.path}'
      '/data/flutter_assets/assets/sounds/ring.wav';

  Future<void> start(String caller) async {
    if (_ringing) return;
    _ringing = true;
    _loop();
    try {
      final r = await Process.run('notify-send', [
        '--app-name=Tala',
        '--urgency=critical',
        '--print-id',
        '--',
        'Incoming call',
        caller,
      ]);
      _notificationId = (r.stdout as String).trim();
    } catch (e) {
      log('ringer: notification failed: $e');
    }
  }

  Future<void> _loop() async {
    while (_ringing) {
      try {
        _player = await Process.start(
          ringPlayer(Platform.environment),
          [_sound],
        );
        final code = await _player!.exitCode;
        if (code != 0 && _ringing) {
          log('ringer: player exited with $code');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        log('ringer: could not play sound: $e');
        _ringing = false;
      }
    }
  }

  Future<void> stop() async {
    _ringing = false;
    _player?.kill();
    _player = null;
    final id = _notificationId;
    _notificationId = null;
    if (id != null && id.isNotEmpty) {
      await Process.run('gdbus', [
        'call',
        '--session',
        '--dest=org.freedesktop.Notifications',
        '--object-path=/org/freedesktop/Notifications',
        '--method=org.freedesktop.Notifications.CloseNotification',
        id,
      ]);
    }
  }
}
