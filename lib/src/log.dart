import 'dart:io';

import 'paths.dart';

const _rotateAtBytes = 2000000;

/// Keeps earlier sessions, because a problem report needs what led up to it.
final File _file = () {
  final dir = configDir..createSync(recursive: true);
  final current = File('${dir.path}/log.txt');
  if (current.existsSync() && current.lengthSync() > _rotateAtBytes ~/ 2) {
    _rotate(current);
  }
  return current;
}();

void _rotate(File current) {
  current.renameSync('${current.parent.path}/log.previous.txt');
}

int _written = 0;

/// Never pass passwords, tickets, SDP, names or message text to this. Reports
/// mask addresses and accounts, but can't recognize anything else.
void log(String message) {
  final line = '${DateTime.now().toIso8601String().substring(11, 23)} $message';
  stdout.writeln(line);
  // Tests must not replace the log of a real session.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  _written += line.length + 1;
  if (_written > _rotateAtBytes) {
    if (_file.existsSync()) _rotate(_file);
    _written = 0;
  }
  _file.writeAsStringSync('$line\n', mode: FileMode.append);
}
