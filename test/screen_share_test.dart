import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/screen_share.dart';

void main() {
  Map<String, dynamic> event(String stream, Object? state) => {
    'portalScreenCast': {
      'event': 'portalScreenCast',
      'streamId': stream,
      'state': state,
    },
  };

  test('reads each state the plugin sends', () {
    expect(shareStateOf(event('a', 'sharing'), 'a'), ShareState.sharing);
    expect(shareStateOf(event('a', 'cancelled'), 'a'), ShareState.cancelled);
    expect(shareStateOf(event('a', 'stopped'), 'a'), ShareState.stopped);
    expect(shareStateOf(event('a', 'failed'), 'a'), ShareState.failed);
  });

  test('anything unknown counts as failed, so a share never hangs', () {
    expect(shareStateOf(event('a', 'odd'), 'a'), ShareState.failed);
    expect(shareStateOf(event('a', null), 'a'), ShareState.failed);
  });

  test('ignores other shares and other events', () {
    expect(shareStateOf(event('b', 'sharing'), 'a'), isNull);
    expect(shareStateOf({'onDeviceChange': {}}, 'a'), isNull);
  });
}
