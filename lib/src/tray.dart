import 'dart:async';

import 'package:flutter/services.dart';

import 'log.dart';

/// Talks to the tray code in the Linux runner. The channel is absent on other
/// platforms for now, which is harmless: calls here do nothing there.
class AppTray {
  static const MethodChannel _channel = MethodChannel('tala/tray');

  /// Long enough to leave a call, short of the runner's own five second limit.
  static const Duration quitLimit = Duration(seconds: 3);

  void start({required Future<void> Function() onQuit}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'quit') {
        try {
          await onQuit().timeout(quitLimit);
        } catch (e) {
          log('tray: cleanup before quit failed: $e');
        }
      }
    });
  }

  void stop() => _channel.setMethodCallHandler(null);

  Future<void> show() => _call('show');

  int? _badge;

  /// The count on the dock icon. Zero removes it.
  Future<void> setBadge(int count) async {
    if (count == _badge) return;
    _badge = count;
    await _call('badge', count);
  }

  /// Asks to close the window, the same way its close button does.
  Future<void> close() => _call('close');

  /// Whether Tala starts at login, or null where that isn't built yet.
  static Future<bool?> startAtLogin() async {
    try {
      return await _channel.invokeMethod<bool>('getAutostart');
    } on MissingPluginException {
      return null;
    } catch (e) {
      log('tray: reading start at login failed: $e');
      return null;
    }
  }

  /// Returns whether the change was made.
  static Future<bool> setStartAtLogin(bool enabled) async {
    try {
      return await _channel.invokeMethod<bool>('setAutostart', enabled) ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      log('tray: changing start at login failed: $e');
      return false;
    }
  }

  /// Whether a tray host is showing the icon.
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No tray code on this platform yet.
    } catch (e) {
      log('tray: $method failed: $e');
    }
  }
}
