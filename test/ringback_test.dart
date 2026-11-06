import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/frame_log.dart';
import 'package:tala/src/ringer.dart';

void main() {
  group('Ringback', () {
    Future<Process> sleeper() => Process.start('sleep', ['30']);

    test('repeats with a gap until stopped', () async {
      var plays = 0;
      final r = Ringback(
        launch: () {
          plays++;
          return Process.start('true', []);
        },
        gap: const Duration(milliseconds: 10),
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      r.stop();
      expect(plays, greaterThan(1));
      final after = plays;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(plays, after);
    });

    test('stopping kills the sound that is playing', () async {
      late Process p;
      final r = Ringback(launch: () async => p = await sleeper())..start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      r.stop();
      expect(await p.exitCode.timeout(const Duration(seconds: 2)), isNot(0));
    });

    test('stops by itself at the limit', () async {
      late Process p;
      final r = Ringback(
        launch: () async => p = await sleeper(),
        limit: const Duration(milliseconds: 100),
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(r.isOn, isFalse);
      await p.exitCode.timeout(const Duration(seconds: 2));
    });

    test('does not start again in the same call', () async {
      var plays = 0;
      final r = Ringback(launch: () {
        plays++;
        return Process.start('true', []);
      })..start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      r.stop();
      r.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(plays, 1);
      expect(r.isOn, isFalse);
    });

    test('a missing player turns it off instead of throwing', () async {
      final r = Ringback(
        launch: () => Process.start('tala-no-such-player', []),
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(r.isOn, isFalse);
    });

    test('the sound is bundled', () {
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('assets/sounds/ringback.wav'));
      expect(File('assets/sounds/ringback.wav').existsSync(), isTrue);
    });
  });

  group('FrameStats', () {
    test('counts slow frames by build plus raster time', () {
      final s = FrameStats()
        ..add(5, 5)
        ..add(20, 20)
        ..add(1, 33);
      expect(s.count, 3);
      expect(s.slow, 2);
      expect(s.summary(), contains('3 frames, 2 slow'));
    });

    test('percentile covers the worst value and an empty list', () {
      expect(FrameStats.percentile([1, 2, 3], 1), 3);
      expect(FrameStats.percentile([], .5), 0);
    });
  });
}
