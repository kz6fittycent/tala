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
}
