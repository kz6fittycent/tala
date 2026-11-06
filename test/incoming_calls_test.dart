import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/incoming_calls.dart';

class FakeSource implements CallSource {
  List<CallNote>? notes = const [];
  Map<String, CallState> states = {};
  List<int> dismissed = [];

  @override
  Future<List<CallNote>?> callNotifications() async => notes;
  @override
  Future<CallState> callState(String token) async =>
      states[token] ?? CallState.pending;
  @override
  Future<void> dismissNotification(int id) async => dismissed.add(id);
}

const note = CallNote(1, 'abc', 'Friend', true);

void main() {
  late FakeSource source;
  late IncomingCalls calls;

  setUp(() {
    source = FakeSource();
    calls = IncomingCalls(source);
  });

  test('rings for a pending call', () async {
    source.notes = [note];
    await calls.check();
    expect(calls.current?.token, 'abc');
  });

  test('does not ring for a missed call', () async {
    source.notes = [note];
    source.states['abc'] = CallState.missed;
    await calls.check();
    expect(calls.current, isNull);
  });

  test('does not ring for a call already joined elsewhere', () async {
    source.notes = [note];
    source.states['abc'] = CallState.joined;
    await calls.check();
    expect(calls.current, isNull);
  });

  test('keeps ringing while nothing has changed on the server', () async {
    source.notes = [note];
    await calls.check();
    source.notes = null; // 304
    await calls.check();
    expect(calls.current?.id, 1);
  });

  test('stops when the caller gives up', () async {
    source.notes = [note];
    await calls.check();
    source.states['abc'] = CallState.missed;
    await calls.check();
    expect(calls.current, isNull);
  });

  test('stops when another device answers and removes the notification',
      () async {
    source.notes = [note];
    await calls.check();
    source.notes = const [];
    await calls.check();
    expect(calls.current, isNull);
  });

  test('decline dismisses it and it does not ring again', () async {
    source.notes = [note];
    await calls.check();
    await calls.decline();
    expect(source.dismissed, [1]);
    await calls.check();
    expect(calls.current, isNull);
  });

  test('accept returns the call and it does not ring again', () async {
    source.notes = [note];
    await calls.check();
    expect((await calls.accept())?.token, 'abc');
    await calls.check();
    expect(calls.current, isNull);
  });

  test('does not ring during a call, and rings for a later one', () async {
    source.notes = [note];
    calls.suspended = true;
    await calls.check();
    expect(calls.current, isNull);
    calls.suspended = false;
    await calls.check();
    expect(calls.current?.id, 1);
  });
}
