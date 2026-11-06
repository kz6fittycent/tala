import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/ringer.dart';

void main() {
  test('a snap plays through PulseAudio, anything else through PipeWire', () {
    expect(ringPlayer({'SNAP': '/snap/tala/1'}), 'paplay');
    expect(ringPlayer({}), 'pw-play');
  });
}
