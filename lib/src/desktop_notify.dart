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
List<String> notifyArgs(String title, String body) => [
      '--app-name=Tala',
      '--print-id',
      '--',
      title,
      escapeMarkup(body),
    ];

/// Linux-only for now, like Ringer: a snap has to ship notify-send, and Mac
/// and Windows need their own version. There's no click action, because
/// Wayland won't let the app bring its own window forward anyway.
class DesktopNotifier {
  /// Notification id by key; null while the id is still on its way.
  final Map<String, String?> _shown = {};
  bool _reportedFailure = false;

  /// Shows one notification per [key], replacing any earlier one.
  Future<void> show(String key, String title, String body) async {
    close(key);
    _shown[key] = null;
    try {
      final r = await Process.run('notify-send', notifyArgs(title, body));
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
