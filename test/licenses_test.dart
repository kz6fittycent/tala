import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/licenses.dart';

void main() {
  test('splits sections and keeps their text', () {
    final parsed = parseBundledLicenses(
      '@@@ One\nfirst line\n\nsecond line\n\n@@@ Two (x)\nother\n',
    );
    expect(parsed, [
      ('One', 'first line\n\nsecond line'),
      ('Two (x)', 'other'),
    ]);
  });

  test('the blur model\'s license ships and is declared', () {
    final text = File('assets/licenses/mediapipe_selfie.txt').readAsStringSync();
    expect(text, contains('MediaPipe Selfie Segmentation'));
    expect(text, contains('Apache License'));
    expect(File('pubspec.yaml').readAsStringSync(),
        contains('assets/licenses/mediapipe_selfie.txt'));
    expect(File('third_party/flutter_webrtc/linux/selfie_model_data.inc')
        .readAsStringSync(), contains('Apache License 2.0'));
  });

  test('the shipped file covers what libwebrtc.so compiles in', () {
    final parsed = parseBundledLicenses(
      File('assets/licenses/libwebrtc.txt').readAsStringSync(),
    );
    final byName = {for (final (name, text) in parsed) name: text};
    for (final required in const [
      'libwebrtc',
      'WebRTC',
      'BoringSSL',
      'dav1d',
      'FFmpeg',
      'libaom',
      'libvpx',
      'OpenH264',
      'Opus',
    ]) {
      expect(byName[required], isNotNull, reason: required);
      expect(byName[required]!.length, greaterThan(200), reason: required);
    }
    expect(byName['WebRTC'], contains('The WebRTC project authors'));
    expect(byName['FFmpeg'], contains('GNU LESSER GENERAL PUBLIC LICENSE'));
  });

  test('LICENSE states or-later and credits FFmpeg with its source', () {
    final license = File('LICENSE').readAsStringSync();
    expect(license, contains('AGPL-3.0-or-later'));
    expect(license, contains('GNU Lesser General Public License'));
    expect(license, contains('libwebrtc.m150.7871.07'));
    expect(license, contains('ad41607c61898cf7150e0fb20fe4bbabd44922a3'));
  });

  test('the license page gets Tala, WebRTC and FFmpeg from real assets', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final packages = entries.expand((e) => e.packages).toSet();
    expect(packages, containsAll(const ['Tala', 'WebRTC', 'FFmpeg']));
  });
}
