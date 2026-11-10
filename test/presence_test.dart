import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException;
import 'package:tala/src/nc_api.dart';
import 'package:tala/src/presence.dart';

void main() {
  group('Presence', () {
    late List<bool> beats;
    late DateTime now;
    Object? beatError;

    Presence make() => Presence(
      heartbeat: ({required bool away}) async {
        final e = beatError;
        if (e != null) throw e;
        beats.add(away);
        return UserStatus(away ? 'away' : 'online');
      },
      fetchOwn: () async => const UserStatus('online'),
      setOwn: (_) async {},
      now: () => now,
    );

    setUp(() {
      beats = [];
      now = DateTime(2026);
      beatError = null;
    });

    test('online while focused, away after five unfocused minutes', () {
      fakeAsync((async) {
        final p = make()..start(focused: true);
        async.flushMicrotasks();
        expect(beats, [false]);
        p.focusChanged(false);
        now = now.add(const Duration(minutes: 5));
        async.elapse(const Duration(minutes: 5));
        expect(beats, [false, true]);
        expect(p.own?.type, 'away');
        // Back at the window: said at once, not at the next beat.
        p.focusChanged(true);
        async.flushMicrotasks();
        expect(beats, [false, true, false]);
        p.dispose();
      });
    });

    test('a short glance away still counts as here', () {
      fakeAsync((async) {
        final p = make()..start(focused: true);
        p.focusChanged(false);
        now = now.add(const Duration(minutes: 2));
        async.elapse(const Duration(minutes: 5));
        expect(beats, [false, false]);
        p.dispose();
      });
    });

    test('a server without user status stops asking', () {
      fakeAsync((async) {
        beatError = ApiException(404, 'heartbeat');
        final p = make()..start(focused: true);
        async.flushMicrotasks();
        expect(p.available, isFalse);
        beatError = null;
        async.elapse(const Duration(minutes: 15));
        expect(beats, isEmpty);
        p.dispose();
      });
    });
  });

  test('a one-to-one carries the other person\'s status', () {
    final r = Room.fromJson({
      'token': 't',
      'type': 1,
      'displayName': 'Maya',
      'status': 'away',
      'statusMessage': 'Lunch',
      'statusIcon': '🍜',
    });
    expect(r.status?.type, 'away');
    expect(r.status?.summary, 'Away · 🍜 Lunch');
    final group = Room.fromJson({'token': 't', 'type': 2, 'status': 'away'});
    expect(group.status, isNull);
  });

  test('offline with no message has no line', () {
    expect(const UserStatus('offline').summary, isNull);
    expect(const UserStatus('invisible').summary, isNull);
    expect(const UserStatus('dnd').summary, 'Do not disturb');
  });

  testWidgets('the status dialog sets what was picked', (tester) async {
    final set = <String>[];
    final p = Presence(
      heartbeat: ({required bool away}) async => null,
      fetchOwn: () async => const UserStatus('online'),
      setOwn: (t) async => set.add(t),
    )..own = const UserStatus('online');
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => StatusDialog(presence: p),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do not disturb'));
    await tester.pumpAndSettle();
    expect(set, ['dnd']);
    expect(p.own?.type, 'dnd');
    expect(find.text('Your status'), findsNothing);
  });
}
