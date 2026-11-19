import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'backgrounds.dart';
import 'log.dart';
import 'paths.dart';

/// Choices that belong to this computer. None of this goes to the server, so
/// other devices and the user's archive are unaffected.
class AppSettings extends ChangeNotifier {
  AppSettings({File? file})
    : _file = file ??
          File('${configDir.path}/settings.json') {
    _load();
  }

  final File _file;
  bool _hideArchived = false;
  bool _archivedOpen = false;
  ThemeMode _themeMode = ThemeMode.system;
  Accent _accent = accents.first;
  bool _messageSound = true;
  bool _callChatOpen = true;
  CallBackground _callBackground = CallBackground.none;
  bool _callTouchUpOn = false;
  double _callTouchUp = defaultTouchUp;
  bool _callNoiseCancel = false;

  /// Where the touch up slider starts.
  static const defaultTouchUp = 0.5;

  /// Takes the Archived section out of the list altogether.
  bool get hideArchived => _hideArchived;
  set hideArchived(bool value) => _change(() => _hideArchived = value);

  /// Whether the Archived section is expanded. Starts collapsed.
  bool get archivedOpen => _archivedOpen;
  set archivedOpen(bool value) => _change(() => _archivedOpen = value);

  ThemeMode get themeMode => _themeMode;
  set themeMode(ThemeMode value) => _change(() => _themeMode = value);

  Accent get accent => _accent;
  set accent(Accent value) => _change(() => _accent = value);

  /// Chime with new-message popups. The desktop still decides whether it plays.
  bool get messageSound => _messageSound;
  set messageSound(bool value) => _change(() => _messageSound = value);

  /// Whether a call shows the conversation's chat beside the video.
  bool get callChatOpen => _callChatOpen;
  set callChatOpen(bool value) => _change(() => _callChatOpen = value);

  /// What calls start with behind the user: nothing, a blur or a picture.
  CallBackground get callBackground => _callBackground;
  set callBackground(CallBackground value) =>
      _change(() => _callBackground = value);

  /// Whether calls smooth the user's skin, and by how much (0 to 1); the
  /// amount is kept while it's off.
  bool get callTouchUpOn => _callTouchUpOn;
  set callTouchUpOn(bool value) => _change(() => _callTouchUpOn = value);

  double get callTouchUp => _callTouchUp;
  set callTouchUp(double value) =>
      _change(() => _callTouchUp = value.clamp(0.0, 1.0));

  /// What a call passes as its touch up: the amount, or 0 while it's off.
  double get callTouchUpAmount => _callTouchUpOn ? _callTouchUp : 0;

  /// Whether calls take background noise out of the user's microphone.
  bool get callNoiseCancel => _callNoiseCancel;
  set callNoiseCancel(bool value) => _change(() => _callNoiseCancel = value);

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
      _accent = accentNamed(d['accent'] as String?);
      _messageSound = d['messageSound'] != false;
      _callChatOpen = d['callChatOpen'] != false;
      // blurBackground is from before pictures (0.8.x).
      _callBackground = d['callBackground'] is String
          ? CallBackground.fromId(d['callBackground'] as String)
          : d['blurBackground'] == true
              ? CallBackground.blur
              : CallBackground.none;
      _callTouchUpOn = d['callTouchUpOn'] == true;
      final touchUp = d['callTouchUp'];
      if (touchUp is num) _callTouchUp = touchUp.toDouble().clamp(0.0, 1.0);
      _callNoiseCancel = d['callNoiseCancel'] == true;
      for (final mode in ThemeMode.values) {
        if (d['theme'] == mode.name) _themeMode = mode;
      }
    } on TypeError {
      log('settings: could not be read, using defaults');
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
        'accent': _accent.name,
        'messageSound': _messageSound,
        'callChatOpen': _callChatOpen,
        'callBackground': _callBackground.id,
        'callTouchUpOn': _callTouchUpOn,
        'callTouchUp': _callTouchUp,
        'callNoiseCancel': _callNoiseCancel,
      }));
      temp.renameSync(_file.path);
    } on FileSystemException catch (e) {
      log('settings: could not be saved: ${e.osError?.message}');
    }
  }
}
