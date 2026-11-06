import 'dart:io';

import 'paths.dart';

/// Never pass passwords, tickets or SDP to this.
final File _file = () {
  final dir = configDir..createSync(recursive: true);
  final current = File('${dir.path}/log.txt');
  if (current.existsSync()) current.copySync('${dir.path}/log.previous.txt');
  return current..writeAsStringSync('');
}();

void log(String message) {
  final line = '${DateTime.now().toIso8601String().substring(11, 23)} $message';
  stdout.writeln(line);
  // Tests must not replace the log of a real session.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  _file.writeAsStringSync('$line\n', mode: FileMode.append);
}
