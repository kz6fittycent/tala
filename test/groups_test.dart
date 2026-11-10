import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException;
import 'package:tala/src/groups.dart';
import 'package:tala/src/nc_api.dart';

Member member(
  int id,
  String name, {
  int type = 3,
  String actorType = 'users',
  String? actorId,
}) => Member(
  attendeeId: id,
  actorType: actorType,
  actorId: actorId ?? name.toLowerCase(),
  name: name,
  participantType: type,
);

Room room(int type, {int participantType = 1, String remote = ''}) =>
    Room.fromJson({
      'token': 't',
      'displayName': 'R',
      'type': type,
      'participantType': participantType,
      'remoteServer': remote,
    });

/// Opens [dialog] from a button, as the app does, and returns what it closed
/// with through [result].
Future<void> open<T>(
  WidgetTester tester,
  Widget dialog, {
  void Function(T?)? result,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final r = await showDialog<T>(
                context: context,
                builder: (_) => dialog,
              );
              result?.call(r);
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

Future<void> searchFor(WidgetTester tester, String label, String text) async {
  await tester.enterText(find.widgetWithText(TextField, label), text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  group('who can do what', () {
    test('only groups and public conversations have members', () {
      expect(room(1).hasMembers, isFalse);
      expect(room(2).hasMembers, isTrue);
      expect(room(3).hasMembers, isTrue);
      expect(room(4).hasMembers, isFalse);
      expect(room(6).hasMembers, isFalse);
    });

    test('moderators manage local conversations, not federated ones', () {
      expect(room(2).canManage, isTrue);
      expect(room(2, participantType: 2).canManage, isTrue);
      expect(room(2, participantType: 3).canManage, isFalse);
      expect(room(1).canManage, isFalse);
      expect(room(2, remote: 'https://other.example').canManage, isFalse);
    });

    test('a group or an owner can\'t be made a moderator', () {
      expect(member(1, 'A').canBeModerator, isTrue);
      expect(member(1, 'A', type: 1).canBeModerator, isFalse);
      expect(member(1, 'A', actorType: 'groups').canBeModerator, isFalse);
      expect(member(1, 'A', actorType: 'guests', type: 4).canBeModerator, isTrue);
    });

    test('a guest with no name still reads as someone', () {
      final guest = member(1, '', type: 4, actorType: 'guests', actorId: 'x');
      expect(guest.displayName, 'Guest');
      expect(guest.role, 'Guest');
    });
  });

  group('new group', () {
    Future<List<Person>> search(String q) async => [
      Person('sam', 'Sam Rivers', ''),
      Person('kit', 'Kit Lane', ''),
    ];

    testWidgets('needs a name, then creates it and adds the people picked', (
      tester,
    ) async {
      final added = <String>[];
      String? created;
      NewGroup? result;
      await open<NewGroup>(
        tester,
        NewGroupDialog(
          search: search,
          create: (name) async {
            created = name;
            return 'tok';
          },
          add: (token, p) async => added.add('$token/${p.id}'),
        ),
        result: (r) => result = r,
      );
      FilledButton create() => tester.widget(find.byType(FilledButton));
      expect(create().onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Group name'),
        '  Book club ',
      );
      await tester.pump();
      expect(create().onPressed, isNotNull);

      await searchFor(tester, 'Add people', 'a');
      await tester.tap(find.text('Sam Rivers'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'Sam Rivers'), findsOneWidget);

      // Someone already picked isn't offered again.
      await searchFor(tester, 'Add people', 'a');
      expect(find.widgetWithText(ListTile, 'Sam Rivers'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'Kit Lane'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(created, 'Book club');
      expect(added, ['tok/sam', 'tok/kit']);
      expect(result?.token, 'tok');
      expect(result?.notAdded, isEmpty);
    });

    testWidgets('someone who can\'t be added doesn\'t lose the group', (
      tester,
    ) async {
      NewGroup? result;
      await open<NewGroup>(
        tester,
        NewGroupDialog(
          search: search,
          create: (_) async => 'tok',
          add: (_, p) async {
            if (p.id == 'sam') throw ApiException(404, 'p');
          },
        ),
        result: (r) => result = r,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Group name'),
        'G',
      );
      await searchFor(tester, 'Add people', 'a');
      await tester.tap(find.text('Sam Rivers'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(result?.token, 'tok');
      expect(result?.notAdded.map((p) => p.id), ['sam']);
    });

    testWidgets('many people in a short window don\'t overflow', (tester) async {
      tester.view.physicalSize = const Size(800, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open<NewGroup>(
        tester,
        NewGroupDialog(
          search: (_) async => [
            for (var i = 0; i < 40; i++) Person('p$i', 'Person number $i', ''),
          ],
          create: (_) async => 'tok',
          add: (_, _) async {},
        ),
      );
      for (var i = 0; i < 20; i++) {
        await searchFor(tester, 'Add people', 'p');
        await tester.tap(find.byType(ListTile).first);
        await tester.pumpAndSettle();
      }
      await searchFor(tester, 'Add people', 'p');
      expect(tester.takeException(), isNull);
      expect(find.text('Create'), findsOneWidget);
    });

    testWidgets('a refused creation stays open and says why', (tester) async {
      await open<NewGroup>(
        tester,
        NewGroupDialog(
          search: search,
          create: (_) async => throw ApiException(403, 'p'),
          add: (_, _) async {},
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Group name'),
        'G',
      );
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('doesn\'t let you'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
    });
  });

  group('members', () {
    List<Member> people() => [
      member(3, 'zed'),
      member(2, 'Kit', type: 2),
      member(1, 'Me', type: 1, actorId: 'me'),
      member(4, 'Team', actorType: 'groups'),
    ];

    MembersDialog dialog({
      bool canManage = true,
      Future<List<Member>> Function()? load,
      Future<void> Function(Person)? add,
      Future<void> Function(int)? remove,
      Future<void> Function(int, bool)? setModerator,
    }) => MembersDialog(
      name: 'Book club',
      selfId: 'me',
      canManage: canManage,
      load: load ?? () async => people(),
      search: (q) async => [
        for (final p in [
          Person('zed', 'zed', ''),
          Person('new', 'New Person', ''),
          Person('staff', 'Staff', '', source: 'groups'),
        ])
          if (p.name.toLowerCase().contains(q)) p,
      ],
      add: add ?? (_) async {},
      remove: remove ?? (_) async {},
      setModerator: setModerator ?? (_, _) async {},
    );

    testWidgets('moderators first, with roles, and a count', (tester) async {
      await open<void>(tester, dialog());
      expect(find.text('Book club (4)'), findsOneWidget);
      expect(find.text('You · Owner'), findsOneWidget);
      expect(find.text('Moderator'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
      final y = [
        'Kit',
        'Me',
        'Team',
        'zed',
      ].map((n) => tester.getTopLeft(find.text(n)).dy).toList();
      expect(y, orderedEquals([...y]..sort()));
    });

    testWidgets('someone who can\'t manage only reads the list', (tester) async {
      await open<void>(tester, dialog(canManage: false));
      expect(find.text('Book club (4)'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    });

    testWidgets('no options on yourself or the owner', (tester) async {
      await open<void>(tester, dialog());
      // Kit, Team and zed. "Me" is both self and owner.
      expect(find.byType(PopupMenuButton<String>), findsNWidgets(3));
      expect(find.byTooltip('Options for Me'), findsNothing);
    });

    testWidgets('a group entry can be removed, not promoted', (tester) async {
      await open<void>(tester, dialog());
      await tester.tap(find.byTooltip('Options for Team'));
      await tester.pumpAndSettle();
      expect(find.text('Make moderator'), findsNothing);
      expect(find.text('Remove…'), findsOneWidget);
    });

    testWidgets('adds someone, skips who\'s already in, and reloads', (
      tester,
    ) async {
      final added = <String>[];
      var loads = 0;
      await open<void>(
        tester,
        dialog(
          load: () async {
            loads++;
            return people();
          },
          add: (p) async => added.add(p.id),
        ),
      );
      await searchFor(tester, 'Add a person, group or team', 'e');
      expect(find.widgetWithText(ListTile, 'New Person'), findsOneWidget);
      // zed is on the list below, but not offered above it.
      expect(find.text('zed'), findsOneWidget);
      await tester.tap(find.text('New Person'));
      await tester.pumpAndSettle();
      expect(added, ['new']);
      expect(loads, 2);
    });

    testWidgets('a whole group can be added, marked as a group', (
      tester,
    ) async {
      final added = <String>[];
      await open<void>(
        tester,
        dialog(add: (p) async => added.add(p.key)),
      );
      await searchFor(tester, 'Add a person, group or team', 'st');
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Staff'),
          matching: find.byIcon(Icons.groups_outlined),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Staff'));
      await tester.pumpAndSettle();
      expect(added, ['groups:staff']);
    });

    testWidgets('promotes, demotes and removes with the right person', (
      tester,
    ) async {
      final calls = <String>[];
      await open<void>(
        tester,
        dialog(
          remove: (id) async => calls.add('remove $id'),
          setModerator: (id, on) async => calls.add('moderator $id $on'),
        ),
      );
      await tester.tap(find.byTooltip('Options for zed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make moderator'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Options for Kit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove as moderator'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Options for zed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove…'));
      await tester.pumpAndSettle();
      expect(calls, ['moderator 3 true', 'moderator 2 false']);
      expect(find.text('Remove zed?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(calls.last, 'remove 3');
    });

    testWidgets('cancelling a removal removes nobody', (tester) async {
      final calls = <int>[];
      await open<void>(tester, dialog(remove: (id) async => calls.add(id)));
      await tester.tap(find.byTooltip('Options for zed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });

    testWidgets('shows a refusal and keeps the list', (tester) async {
      await open<void>(
        tester,
        dialog(setModerator: (_, _) async => throw ApiException(403, 'p')),
      );
      await tester.tap(find.byTooltip('Options for zed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make moderator'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Only moderators'), findsOneWidget);
      expect(find.text('zed'), findsOneWidget);
    });

    testWidgets('search results in a short window don\'t overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open<void>(tester, dialog());
      await searchFor(tester, 'Add a person, group or team', 'e');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed load offers another try', (tester) async {
      var fail = true;
      await open<void>(
        tester,
        dialog(
          load: () async {
            if (fail) throw ApiException(500, 'p');
            return people();
          },
        ),
      );
      expect(find.textContaining('Couldn\'t load'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Book club (4)'), findsOneWidget);
    });
  });

  group('rename', () {
    testWidgets('saves only a real change, trimmed', (tester) async {
      final names = <String>[];
      bool? result;
      await open<bool>(
        tester,
        RenameDialog(name: 'Old', rename: (n) async => names.add(n)),
        result: (r) => result = r,
      );
      FilledButton save() => tester.widget(find.byType(FilledButton));
      expect(save().onPressed, isNull);
      await tester.enterText(find.byType(TextField), '  ');
      await tester.pump();
      expect(save().onPressed, isNull);
      await tester.enterText(find.byType(TextField), ' New ');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(names, ['New']);
      expect(result, isTrue);
    });

    testWidgets('a description is saved alone when only it changed', (
      tester,
    ) async {
      final calls = <String>[];
      await open<bool>(
        tester,
        RenameDialog(
          name: 'Club',
          rename: (n) async => calls.add('name $n'),
          description: 'Old',
          describe: (d) async => calls.add('description $d'),
        ),
      );
      expect(find.text('Edit conversation'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        ' Books, monthly ',
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(calls, ['description Books, monthly']);
    });

    testWidgets('a failure stays open', (tester) async {
      await open<bool>(
        tester,
        RenameDialog(
          name: 'Old',
          rename: (_) async => throw ApiException(500, 'p'),
        ),
      );
      await tester.enterText(find.byType(TextField), 'New');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t save'), findsOneWidget);
    });
  });
}
