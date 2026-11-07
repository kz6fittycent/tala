import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException;
import 'package:tala/src/guest_link.dart';
import 'package:tala/src/nc_api.dart';

Widget _host(Widget dialog, void Function(Object?) done) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () async => done(
          await showDialog<Object>(context: context, builder: (_) => dialog),
        ),
        child: const Text('go'),
      ),
    ),
  ),
);

Room _room(Map<String, dynamic> extra) => Room.fromJson({
  'token': 'abc',
  'displayName': 'Picnic',
  'type': 3,
  ...extra,
});

void main() {
  test('the link works with or without a trailing slash', () {
    const want = 'https://cloud.example.com/index.php/call/abc';
    expect(guestLink('https://cloud.example.com', 'abc'), want);
    expect(guestLink('https://cloud.example.com/', 'abc'), want);
  });

  test('only local public conversations have a guest link', () {
    expect(_room({}).hasGuestLink, isTrue);
    expect(_room({'type': 2}).hasGuestLink, isFalse);
    expect(_room({'remoteServer': 'https://other'}).hasGuestLink, isFalse);
    expect(_room({'hasPassword': true}).hasPassword, isTrue);
  });

  test(
    'delete is offered only where the server allows it and it\'s needed',
    () {
      Room r(
        int type, {
        bool can = true,
        bool leave = true,
        String remote = '',
      }) => Room.fromJson({
        'token': 't',
        'displayName': 'n',
        'type': type,
        'canDeleteConversation': can,
        'canLeaveConversation': leave,
        'remoteServer': remote,
      });
      expect(r(3).offersDelete, isTrue);
      expect(
        r(2, leave: false).offersDelete,
        isTrue,
        reason: 'link turned off',
      );
      expect(r(2).offersDelete, isFalse, reason: 'can leave, so leave');
      expect(r(3, can: false).offersDelete, isFalse);
      expect(r(1, leave: false).offersDelete, isFalse);
      expect(r(6, leave: false).offersDelete, isFalse);
      expect(r(3, remote: 'https://x').offersDelete, isFalse);
    },
  );

  group('deleting', () {
    Future<void> open(WidgetTester tester, void Function(bool) done) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    done(await confirmDeleteForEveryone(context, 'Picnic')),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('cancelling or dismissing doesn\'t confirm', (tester) async {
      bool? answer;
      await open(tester, (a) => answer = a);
      expect(find.text('Delete Picnic for everyone?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
      answer = null;
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
    });

    testWidgets('only the delete button confirms', (tester) async {
      bool? answer;
      await open(tester, (a) => answer = a);
      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });

  group('creating', () {
    Future<void> open(
      WidgetTester tester,
      Future<String> Function(String, String) create,
      void Function(Object?) done,
    ) async {
      await tester.pumpWidget(
        _host(NewGuestConversationDialog(create: create), done),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('needs a name, then closes with the token', (tester) async {
      Object? result;
      final calls = <String>[];
      await open(tester, (n, p) async {
        calls.add('$n/$p');
        return 'tok';
      }, (r) => result = r);
      final create = find.widgetWithText(FilledButton, 'Create');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, '  Picnic ');
      await tester.enterText(find.byType(TextField).last, 'pw');
      await tester.pump();
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(calls, ['Picnic/pw']);
      expect(result, 'tok');
    });

    testWidgets('a refusal stays open and mentions the password', (
      tester,
    ) async {
      await open(tester, (_, _) async {
        throw ApiException(400, '/room');
      }, (_) {});
      await tester.enterText(find.byType(TextField).first, 'Picnic');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('require a password'), findsOneWidget);
      expect(find.text('Conversation name'), findsOneWidget);
    });
  });

  group('sharing', () {
    Future<void> open(
      WidgetTester tester, {
      bool canManage = true,
      bool hasPassword = false,
      Future<void> Function(String)? invite,
      Future<bool> Function()? turnOff,
    }) async {
      await tester.pumpWidget(
        _host(
          GuestLinkDialog(
            name: 'Picnic',
            link: 'https://x/index.php/call/abc',
            hasPassword: hasPassword,
            canManage: canManage,
            invite: invite ?? (_) async {},
            turnOff: turnOff ?? () async => false,
          ),
          (_) {},
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('copies the link', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await open(tester);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, 'https://x/index.php/call/abc');
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('someone who isn\'t a moderator only gets the link', (
      tester,
    ) async {
      await open(tester, canManage: false);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Turn off link'), findsNothing);
    });

    testWidgets('a password gets mentioned', (tester) async {
      await open(tester, hasPassword: true);
      expect(
        find.textContaining('Send the password separately'),
        findsOneWidget,
      );
    });

    testWidgets('sends an email, and explains a failure', (tester) async {
      final sent = <String>[];
      var fail = false;
      await open(
        tester,
        invite: (e) async {
          if (fail) throw ApiException(400, '/p');
          sent.add(e);
        },
      );
      final field = find.byType(TextField);
      final send = find.widgetWithText(TextButton, 'Send');
      await tester.enterText(field, 'not an address');
      await tester.pump();
      expect(tester.widget<TextButton>(send).onPressed, isNull);
      await tester.enterText(field, 'pat@example.com');
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent, ['pat@example.com']);
      expect(find.textContaining('sending the invitation'), findsOneWidget);
      fail = true;
      await tester.enterText(field, 'lee@example.com');
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.textContaining('copy the link'), findsOneWidget);
    });

    testWidgets('turning the link off closes only once it worked', (
      tester,
    ) async {
      var answer = false;
      await open(tester, turnOff: () async => answer);
      await tester.tap(find.text('Turn off link'));
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsOneWidget);
      answer = true;
      await tester.tap(find.text('Turn off link'));
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsNothing);
    });
  });
}
