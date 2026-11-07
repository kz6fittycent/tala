import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/avatars.dart';
import 'package:tala/src/nc_api.dart';

/// A 1x1 PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48,
  0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0,
  0, 0, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0, 5, 0, 1, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0, 0, 0, 0, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Room room(
  int type, {
  String name = 'bob',
  bool custom = false,
  String version = 'v1',
}) => Room.fromJson({
  'token': 'tok',
  'name': name,
  'displayName': 'Bob',
  'type': type,
  'isCustomAvatar': custom,
  'avatarVersion': version,
});

void main() {
  group('store', () {
    late List<String> users;
    late List<String> rooms;
    late DateTime now;
    late AvatarStore store;
    Object? fail;

    setUp(() {
      users = [];
      rooms = [];
      fail = null;
      now = DateTime(2026);
      store = AvatarStore(
        now: () => now,
        fetchUser: (id) async {
          users.add(id);
          if (fail != null) throw fail!;
          return _png;
        },
        fetchRoom: (token) async {
          rooms.add(token);
          return _png;
        },
      );
    });

    test('a one-to-one shows the other person, by user id', () async {
      final image = store.forRoom(room(1))!;
      await image.ready;
      expect(users, ['bob']);
      expect(rooms, isEmpty);
      expect(image.bytes, isNotNull);
    });

    test('a group shows a picture only if one was set', () {
      expect(store.forRoom(room(2)), isNull);
      expect(store.forRoom(room(3)), isNull);
      expect(store.forRoom(room(2, custom: true)), isNotNull);
      expect(rooms, ['tok']);
    });

    test('system conversations and missing ids ask for nothing', () {
      expect(store.forRoom(room(4)), isNull);
      expect(store.forRoom(room(6)), isNull);
      expect(store.forRoom(room(1, name: '')), isNull);
      expect(store.forUser(''), isNull);
      expect(users, isEmpty);
    });

    test('asks once, then again after an hour', () async {
      final first = store.forUser('bob')!;
      expect(identical(store.forUser('bob'), first), isTrue);
      now = now.add(const Duration(minutes: 59));
      expect(identical(store.forUser('bob'), first), isTrue);
      expect(users, ['bob']);
      now = now.add(const Duration(minutes: 2));
      store.forUser('bob');
      expect(users, ['bob', 'bob']);
    });

    test('a new version of a conversation\'s picture is fetched at once', () {
      store.forRoom(room(2, custom: true));
      store.forRoom(room(2, custom: true));
      expect(rooms, ['tok']);
      store.forRoom(room(2, custom: true, version: 'v2'));
      expect(rooms, ['tok', 'tok']);
    });

    test('a failure leaves no picture and is retried soon', () async {
      fail = Exception('offline');
      final image = store.forUser('bob')!;
      await image.ready;
      expect(image.bytes, isNull);
      fail = null;
      now = now.add(const Duration(seconds: 30));
      expect(identical(store.forUser('bob'), image), isTrue);
      now = now.add(const Duration(seconds: 31));
      final again = store.forUser('bob')!;
      await again.ready;
      expect(again.bytes, isNotNull);
    });
  });

  group('widget', () {
    ImageProvider? picture(WidgetTester t) =>
        t.widget<CircleAvatar>(find.byType(CircleAvatar)).foregroundImage;

    Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('the letter shows, and a picture goes over it on arrival', (
      tester,
    ) async {
      final arrival = Completer<Uint8List?>();
      final store = AvatarStore(
        fetchUser: (_) => arrival.future,
        fetchRoom: (_) async => null,
      );
      final image = store.forUser('bob');
      await tester.pumpWidget(app(Avatar(name: 'bob', image: image)));
      expect(find.text('B'), findsOneWidget);
      expect(picture(tester), isNull);
      arrival.complete(_png);
      await tester.pumpAndSettle();
      expect(picture(tester), isNotNull);
      expect(find.text('B'), findsOneWidget, reason: 'beneath, for a bad image');

      // Scrolling back to it shows the picture at once.
      await tester.pumpWidget(app(const SizedBox()));
      await tester.pumpWidget(app(Avatar(name: 'bob', image: image)));
      expect(picture(tester), isNotNull);
    });

    testWidgets('no picture, or a failed one, leaves the letter', (tester) async {
      final store = AvatarStore(
        fetchUser: (id) async => id == 'bad' ? throw Exception('x') : null,
        fetchRoom: (_) async => null,
      );
      await tester.pumpWidget(
        app(Avatar(name: 'none', image: store.forUser('none'))),
      );
      await tester.pumpAndSettle();
      expect(picture(tester), isNull);
      await tester.pumpWidget(
        app(Avatar(name: 'bad', image: store.forUser('bad'))),
      );
      await tester.pumpAndSettle();
      expect(picture(tester), isNull);
      await tester.pumpWidget(app(const Avatar(name: '')));
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('a picture that won\'t decode is not an error', (tester) async {
      final store = AvatarStore(
        fetchUser: (_) async => Uint8List.fromList([1, 2, 3]),
        fetchRoom: (_) async => null,
      );
      await tester.pumpWidget(app(Avatar(name: 'x', image: store.forUser('x'))));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('X'), findsOneWidget);
    });

    testWidgets('changing to someone else drops the old picture', (tester) async {
      final store = AvatarStore(
        fetchUser: (id) async => id == 'bob' ? _png : null,
        fetchRoom: (_) async => null,
      );
      await tester.pumpWidget(app(Avatar(name: 'bob', image: store.forUser('bob'))));
      await tester.pumpAndSettle();
      expect(picture(tester), isNotNull);
      await tester.pumpWidget(app(Avatar(name: 'amy', image: store.forUser('amy'))));
      await tester.pumpAndSettle();
      expect(picture(tester), isNull);
    });
  });
}
