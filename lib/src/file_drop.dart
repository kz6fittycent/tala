import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'log.dart';

/// Files dragged onto the window, from the runner's "tala/drop" channel. The
/// newest open conversation that takes files gets them; others wait their
/// turn beneath it.
class FileDrops {
  FileDrops._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final FileDrops instance = FileDrops._();
  static const MethodChannel _channel = MethodChannel('tala/drop');

  /// True while a drag carrying files is over the window.
  final ValueNotifier<bool> hovering = ValueNotifier(false);

  final List<ValueChanged<List<String>>> _targets = [];

  /// Called with dropped paths when nothing can take them.
  ValueChanged<List<String>>? onUnwanted;

  bool get hasTarget => _targets.isNotEmpty;

  /// Whether [target] is the one a drop would go to now.
  bool isCurrent(ValueChanged<List<String>> target) =>
      _targets.isNotEmpty && _targets.last == target;

  void addTarget(ValueChanged<List<String>> target) => _targets.add(target);
  void removeTarget(ValueChanged<List<String>> target) =>
      _targets.remove(target);

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'hover':
        hovering.value = call.arguments == true;
      case 'files':
        hovering.value = false;
        final paths = [
          for (final p in call.arguments as List? ?? const [])
            if (p is String) p,
        ];
        log('drop: ${paths.length} item(s)');
        deliver(paths);
    }
  }

  @visibleForTesting
  void deliver(List<String> paths) {
    if (paths.isEmpty) return;
    if (_targets.isEmpty) {
      onUnwanted?.call(paths);
    } else {
      _targets.last(paths);
    }
  }
}

/// Folders and anything else that isn't a plain file can't be attached, and
/// neither can a file Tala isn't allowed to read (the snap's confinement, when
/// a drop didn't come through the document portal).
({List<String> files, int skipped, int unreadable}) sendableFiles(
  List<String> paths,
) {
  final files = <String>[];
  var skipped = 0;
  var unreadable = 0;
  for (final p in paths) {
    if (FileSystemEntity.typeSync(p) != FileSystemEntityType.file) {
      skipped++;
    } else if (!_readable(p)) {
      unreadable++;
    } else {
      files.add(p);
    }
  }
  return (files: files, skipped: skipped, unreadable: unreadable);
}

bool _readable(String path) {
  try {
    File(path).openSync().closeSync();
    return true;
  } on FileSystemException catch (e) {
    log('drop: can\'t read a dropped file: ${e.osError?.message ?? e.message}');
    return false;
  }
}
