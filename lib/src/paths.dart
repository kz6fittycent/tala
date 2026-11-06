import 'dart:io';

/// Where Tala keeps its settings and logs, moving the folder over from the
/// name it had during the prototype if that's still there.
final Directory configDir = () {
  final env = Platform.environment;
  final xdg = env['XDG_CONFIG_HOME'];
  final base = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME']}/.config';
  final dir = Directory('$base/tala');
  final old = Directory('$base/tala-prototype');
  // Tests must not touch a real session's folder.
  if (!env.containsKey('FLUTTER_TEST') &&
      old.existsSync() &&
      !dir.existsSync()) {
    old.renameSync(dir.path);
  }
  return dir;
}();
