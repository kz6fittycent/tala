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

  test('the license page gets Tala, WebRTC and FFmpeg from real assets', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final packages = entries.expand((e) => e.packages).toSet();
    expect(packages, containsAll(const ['Tala', 'WebRTC', 'FFmpeg']));
  });
}
