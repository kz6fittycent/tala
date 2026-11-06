import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'log.dart';

/// Choices that belong to this computer. None of this goes to the server, so
/// other devices and the user's archive are unaffected.
class AppSettings extends ChangeNotifier {
  AppSettings({File? file})
    : _file = file ??
          File(
            '${Platform.environment['HOME']}'
            '/.config/tala-prototype/settings.json',
          ) {
    _load();
  }

  final File _file;
  bool _hideArchived = false;
  bool _archivedOpen = false;
  ThemeMode _themeMode = ThemeMode.system;

  /// Takes the Archived section out of the list altogether.
  bool get hideArchived => _hideArchived;
  set hideArchived(bool value) => _change(() => _hideArchived = value);

  /// Whether the Archived section is expanded. Starts collapsed.
  bool get archivedOpen => _archivedOpen;
  set archivedOpen(bool value) => _change(() => _archivedOpen = value);

  ThemeMode get themeMode => _themeMode;
  set themeMode(ThemeMode value) => _change(() => _themeMode = value);

  void _change(VoidCallback apply) {
    apply();
    notifyListeners();
    _save();
  }

  void _load() {
    try {
      if (!_file.existsSync()) return;
      final d = jsonDecode(_file.readAsStringSync());
      if (d is! Map) return;
      _hideArchived = d['hideArchived'] == true;
      _archivedOpen = d['archivedOpen'] == true;
      for (final mode in ThemeMode.values) {
        if (d['theme'] == mode.name) _themeMode = mode;
      }
    } on FormatException {
      log('settings: could not be read, using defaults');
    } on FileSystemException catch (e) {
      log('settings: could not be read: ${e.osError?.message}');
    }
  }

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      // Written beside the real file so a crash can't leave half a file.
      final temp = File('${_file.path}.tmp');
      temp.writeAsStringSync(jsonEncode({
        'hideArchived': _hideArchived,
        'archivedOpen': _archivedOpen,
        'theme': _themeMode.name,
      }));
      temp.renameSync(_file.path);
    } on FileSystemException catch (e) {
      log('settings: could not be saved: ${e.osError?.message}');
    }
  }
}
