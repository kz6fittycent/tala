import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/call.dart';

void main() {
  test('flags say what is being sent', () {
    expect(callFlags(audio: true, video: true), 7);
    expect(callFlags(audio: true, video: false), 3);
    expect(callFlags(audio: false, video: true), 5);
    expect(callFlags(audio: false, video: false), 1);
  });

  test('the status only mentions what is missing', () {
    String note(bool a, bool v) => mediaNote(audio: a, video: v, status: 'In call');
    expect(note(true, true), 'In call');
    expect(note(true, false), 'In call (no camera)');
    expect(note(false, true), 'In call (no mic)');
    expect(note(false, false), 'In call (no camera or mic)');
  });

  group('speaking', () {
    final now = DateTime(2026, 11, 19, 12);
    DateTime ago(int ms) => now.subtract(Duration(milliseconds: ms));

    test('lasts a moment after the last loud sound', () {
      expect(speakingNow({'a': ago(100), 'b': ago(2000)}, now), {'a'});
      expect(speakingNow({}, now), isEmpty);
    });

    test('the focus stays through a pause, then goes to the loudest', () {
      String? pick(String? current, Map<String, DateTime> loudAt,
              Map<String, double> levels) =>
          pickSpeaker(
            current: current,
            present: {'a', 'b', 'c'},
            speaking: speakingNow(loudAt, now),
            loudAt: loudAt,
            levels: levels,
            now: now,
          );
      // a paused briefly while b spoke: a keeps it.
      expect(pick('a', {'a': ago(1000), 'b': ago(0)}, {'b': 0.2}), 'a');
      // a has been quiet long enough: the louder of b and c.
      expect(
        pick('a', {'a': ago(3000), 'b': ago(0), 'c': ago(0)},
            {'b': 0.05, 'c': 0.2}),
        'c',
      );
      // Nobody speaks: whoever had it keeps it.
      expect(pick('a', {'a': ago(5000)}, {}), 'a');
      // Nobody yet.
      expect(pick(null, {}, {}), isNull);
    });

    test('someone who left loses the focus', () {
      expect(
        pickSpeaker(
          current: 'gone',
          present: {'a'},
          speaking: {'a'},
          loudAt: {'gone': now, 'a': now},
          levels: {'a': 0.1},
          now: now,
        ),
        'a',
      );
      expect(
        pickSpeaker(
          current: 'gone',
          present: {'a'},
          speaking: const {},
          loudAt: const {},
          levels: const {},
          now: now,
        ),
        isNull,
      );
    });
  });
}
