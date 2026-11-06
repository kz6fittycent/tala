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
  Future<void> hide() => _call('hide');

  Future<void> _call(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // No tray code on this platform yet.
    } catch (e) {
      log('tray: $method failed: $e');
    }
  }
}
