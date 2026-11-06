import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log.dart';

/// How the conversation list looks on this computer. None of this goes to the
/// server, so archiving and other devices are unaffected.
class ListPrefs extends ChangeNotifier {
  ListPrefs({File? file})
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

  /// Takes the Archived section out of the list altogether.
  bool get hideArchived => _hideArchived;
  set hideArchived(bool value) => _change(() => _hideArchived = value);

  /// Whether the Archived section is expanded. Starts collapsed.
  bool get archivedOpen => _archivedOpen;
  set archivedOpen(bool value) => _change(() => _archivedOpen = value);

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
      }));
      temp.renameSync(_file.path);
    } on FileSystemException catch (e) {
      log('settings: could not be saved: ${e.osError?.message}');
    }
  }
}
