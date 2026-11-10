import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log.dart';
import 'mentions.dart';
import 'paths.dart';

/// Unsent text by conversation, with the mentions picked in it, kept on disk
/// so a restart doesn't lose them. Only readable by the user, since it holds
/// message text. Drafts belong to one account: signing in elsewhere starts
/// empty and the old account's drafts are dropped.
class DraftStore {
  DraftStore({
    required this.account,
    File? file,
    this.saveDelay = const Duration(seconds: 1),
  }) : _file = file ?? File('${configDir.path}/drafts.json') {
    _load();
  }

  final String account;
  final File _file;
  final Duration saveDelay;
  final Map<String, String> _text = {};
  final Map<String, PickedMentions> _picked = {};
  Timer? _timer;

  String? operator [](String token) => _text[token];

  void operator []=(String token, String text) {
    if (text.isEmpty) {
      if (_text.remove(token) == null) return;
      _picked.remove(token);
    } else {
      if (_text[token] == text) return;
      _text[token] = text;
    }
    _scheduleSave();
  }

  /// The mentions picked in this conversation's draft. Changes reach the disk
  /// with the next change to the text, which picking always makes.
  PickedMentions picked(String token) =>
      _picked.putIfAbsent(token, PickedMentions.new);

  void remove(String token) {
    final had = _text.remove(token) != null;
    _picked.remove(token);
    if (had) _scheduleSave();
  }

  void _scheduleSave() {
    if (saveDelay == Duration.zero) return flush();
    _timer?.cancel();
    _timer = Timer(saveDelay, flush);
  }

  void _load() {
    try {
      if (!_file.existsSync()) return;
      final d = jsonDecode(_file.readAsStringSync());
      if (d is! Map || d['account'] != account) return;
      final drafts = d['drafts'];
      if (drafts is! Map) return;
      for (final MapEntry(:key, :value) in drafts.entries) {
        if (key is! String || value is! Map) continue;
        final text = value['text'];
        if (text is! String || text.isEmpty) continue;
        _text[key] = text;
        final mentions = value['mentions'];
        if (mentions is Map) {
          _picked[key] = PickedMentions.fromJson(mentions);
        }
      }
    } on FormatException {
      log('drafts: could not be read, starting empty');
    } on FileSystemException catch (e) {
      log('drafts: could not be read: ${e.osError?.message}');
    }
  }

  /// Writes now. Called on a timer after changes, and on the way out.
  void flush() {
    _timer?.cancel();
    _timer = null;
    try {
      _file.parent.createSync(recursive: true);
      final temp = File('${_file.path}.tmp');
      // Created empty and locked down before any text goes in.
      temp.writeAsStringSync('');
      if (!Platform.isWindows) Process.runSync('chmod', ['600', temp.path]);
      temp.writeAsStringSync(
        jsonEncode({
          'account': account,
          'drafts': {
            for (final MapEntry(:key, :value) in _text.entries)
              key: {
                'text': value,
                if (_picked[key] case final p? when !p.isEmpty)
                  'mentions': p.toJson(),
              },
          },
        }),
      );
      temp.renameSync(_file.path);
    } on FileSystemException catch (e) {
      log('drafts: could not be saved: ${e.osError?.message}');
    } on ProcessException catch (e) {
      log('drafts: could not be saved: ${e.message}');
    }
  }
}
