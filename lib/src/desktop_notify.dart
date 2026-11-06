import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log.dart';

/// Notification servers may treat the body as markup, and message text is
/// written by other people.
String escapeMarkup(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// `--` stops text beginning with a dash from being read as an option.
@visibleForTesting
List<String> notifyArgs(String title, String body, {String? soundFile}) => [
      '--app-name=Tala',
      '--print-id',
      if (soundFile != null) '--hint=string:sound-file:$soundFile',
      '--',
      title,
      escapeMarkup(body),
    ];

/// Linux-only for now, like Ringer: Mac and Windows need their own version. There's no click action, because
/// Wayland won't let the app bring its own window forward anyway.
class DesktopNotifier {
  /// Notification id by key; null while the id is still on its way.
  final Map<String, String?> _shown = {};
  bool _reportedFailure = false;
  DateTime? _lastSound;

  /// A burst of messages shouldn't become a burst of chimes.
  static const _soundGap = Duration(seconds: 3);

  String get _soundFile => '${File(Platform.resolvedExecutable).parent.path}'
      '/data/flutter_assets/assets/sounds/message.wav';

  /// The notification server plays it, so Do Not Disturb and the system's own
  /// sound settings apply. A server that ignores the hint stays silent.
  String? _soundForNow() {
    final now = DateTime.now();
    final last = _lastSound;
    if (last != null && now.difference(last) < _soundGap) return null;
    _lastSound = now;
    return _soundFile;
  }

  /// Shows one notification per [key], replacing any earlier one.
  Future<void> show(
    String key,
    String title,
    String body, {
    bool sound = false,
  }) async {
    close(key);
    _shown[key] = null;
    try {
      final r = await Process.run(
        'notify-send',
        notifyArgs(title, body, soundFile: sound ? _soundForNow() : null),
      );
      final id = (r.stdout as String).trim();
      if (!_shown.containsKey(key)) {
        // Closed before the id arrived.
        _closeById(id);
      } else {
        _shown[key] = id;
      }
    } catch (e) {
      if (!_reportedFailure) log('notify: could not show: $e');
      _reportedFailure = true;
    }
  }

  void close(String key) {
    final id = _shown.remove(key);
    if (id != null) _closeById(id);
  }

  void closeAll() {
    for (final k in _shown.keys.toList()) {
      close(k);
    }
  }

  void _closeById(String id) {
    if (int.tryParse(id) == null) return;
    unawaited(Process.run('gdbus', [
      'call',
      '--session',
      '--dest=org.freedesktop.Notifications',
      '--object-path=/org/freedesktop/Notifications',
      '--method=org.freedesktop.Notifications.CloseNotification',
      id,
    ]).then((_) {}, onError: (Object _) {}));
  }
}
