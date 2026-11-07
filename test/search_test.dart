import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException, ChatMessage;
import 'package:tala/src/search.dart';

SearchHit hit(int id, {String token = 'tok', String text = 'words'}) => SearchHit(
  token: token,
  messageId: id,
  title: 'Sam in Family',
  excerpt: text,
  actorType: 'users',
  actorId: 'sam',
  timestamp: 1700000000,
);

ChatMessage msg(int id, String text, {String actor = 'sam', bool system = false}) =>
    ChatMessage.fromJson({
      'id': id,
      'actorType': 'users',
      'actorId': actor,
      'actorDisplayName': actor,
      'timestamp': 1700000000,
      'message': text,
      if (system) 'systemMessage': 'conversation_created',
    });

class Calls {
  final List<(String, String?, Object?)> searches = [];
  final List<(String, int)> contexts = [];
}

void main() {
  group('hits', () {
    test('entries that can\'t be opened are dropped', () {
      expect(SearchHit.fromJson({'title': 'x'}), isNull);
      expect(SearchHit.fromJson({'attributes': []}), isNull);
      expect(
        SearchHit.fromJson({
          'attributes': {'conversation': 'a', 'messageId': 'nope'},
        }),
        isNull,
      );
      expect(
        SearchHit.fromJson({
          'attributes': {'conversation': '', 'messageId': '1'},
        }),
        isNull,
      );
    });

    test('excerpts lose Markdown and line breaks', () {
      expect(plainExcerpt('**bold** and `code`'), 'bold and code');
      expect(plainExcerpt('line one\n\nline two'), 'line one line two');
      expect(plainExcerpt('plain words'), 'plain words');
      expect(plainExcerpt('snake_case stays'), 'snake_case stays');
    });
  });

  group('dialog', () {
    Future<String?> Function() open(
      WidgetTester tester, {
      required Future<SearchPage> Function(String, {String? token, Object? cursor})
      search,
      Future<List<ChatMessage>> Function(String, int)? context,
      String? conversation,
    }) {
      String? result;
      return () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () async {
                    result = await showDialog<String>(
                      context: c,
                      builder: (_) => SearchDialog(
                        search: search,
                        context: context ?? (_, _) async => [msg(1, 'found')],
                        preview: (_) async => Uint8List(0),
                        selfId: 'me',
                        conversation: conversation,
                        conversationName: conversation == null ? null : 'Family',
                      ),
                    );
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        return result;
      };
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    testWidgets('searches once for the final text, and shows hits', (tester) async {
      final terms = <String>[];
      await open(
        tester,
        search: (t, {token, cursor}) async {
          terms.add(t);
          return SearchPage([hit(1, text: 'found words')], 2, false);
        },
      )();
      await tester.enterText(find.byType(TextField), 'fo');
      await tester.pump(const Duration(milliseconds: 100));
      await type(tester, ' found ');
      expect(terms, ['found']);
      expect(find.text('found words'), findsOneWidget);
      expect(find.text('Sam in Family'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('a slow old search can\'t replace a newer one', (tester) async {
      final slow = <String, Future<SearchPage>>{
        'old': Future.delayed(
          const Duration(seconds: 5),
          () => SearchPage([hit(1, text: 'old result')], null, false),
        ),
        'new': Future.value(SearchPage([hit(2, text: 'new result')], null, false)),
      };
      await open(tester, search: (t, {token, cursor}) => slow[t]!)();
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField), 'new');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('new result'), findsOneWidget);
      expect(find.text('old result'), findsNothing);
    });

    testWidgets('scoped to a conversation, says so and passes it on', (tester) async {
      final tokens = <String?>[];
      await open(
        tester,
        conversation: 'tok',
        search: (t, {token, cursor}) async {
          tokens.add(token);
          return const SearchPage([], null, false);
        },
      )();
      expect(find.text('Search Family'), findsOneWidget);
      await type(tester, 'x');
      expect(tokens, ['tok']);
      expect(find.text('No messages found.'), findsOneWidget);
    });

    testWidgets('Show more adds the next page, using the cursor', (tester) async {
      final cursors = <Object?>[];
      await open(
        tester,
        search: (t, {token, cursor}) async {
          cursors.add(cursor);
          return cursor == null
              ? SearchPage([hit(1, text: 'first')], 7, true)
              : SearchPage([hit(2, text: 'second')], 8, false);
        },
      )();
      await type(tester, 'x');
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(cursors, [null, 7]);
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('a failure says so, and clearing the box resets it', (tester) async {
      await open(
        tester,
        search: (t, {token, cursor}) async => throw ApiException(500, 'p'),
      )();
      await type(tester, 'x');
      expect(find.textContaining('Couldn\'t search'), findsOneWidget);
      await type(tester, '');
      expect(find.textContaining('Couldn\'t search'), findsNothing);
    });

    testWidgets('a hit opens among its neighbors, then the conversation', (tester) async {
      final asked = <(String, int)>[];
      String? result;
      final show = open(
        tester,
        search: (t, {token, cursor}) async =>
            SearchPage([hit(5, token: 'room')], null, false),
        context: (token, id) async {
          asked.add((token, id));
          // Out of order, with a hidden entry and a system message.
          return [
            msg(6, 'after'),
            msg(5, 'the found one'),
            msg(4, 'before', actor: 'me'),
            msg(3, 'joined', system: true),
          ];
        },
      );
      await show();
      await type(tester, 'x');
      await tester.tap(find.text('words'));
      await tester.pumpAndSettle();
      expect(asked, [('room', 5)]);
      for (final text in ['before', 'the found one', 'after', 'joined']) {
        expect(find.textContaining(text, findRichText: true), findsWidgets);
      }
      final y = [
        'before',
        'the found one',
        'after',
      ].map((t) => tester.getTopLeft(find.textContaining(t, findRichText: true).first).dy);
      expect(y, orderedEquals([...y]..sort()));
      expect(tester.takeException(), isNull);

      // Back returns to the results, with nothing selected.
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Search messages'), findsOneWidget);
      result = await show();
      expect(result, isNull);
    });

    testWidgets('neighbors show full dates, one per day', (tester) async {
      ChatMessage on(int id, DateTime day) => ChatMessage.fromJson({
        'id': id,
        'actorType': 'users',
        'actorId': 'sam',
        'actorDisplayName': 'sam',
        'timestamp': day.millisecondsSinceEpoch ~/ 1000,
        'message': 'message $id',
      });
      await open(
        tester,
        search: (t, {token, cursor}) async => SearchPage([hit(2)], null, false),
        context: (_, _) async => [
          on(1, DateTime(2019, 3, 4, 10)),
          on(2, DateTime(2019, 3, 4, 11)),
          on(3, DateTime(2019, 3, 5, 9)),
        ],
      )();
      await type(tester, 'x');
      await tester.tap(find.text('words'));
      await tester.pumpAndSettle();
      expect(find.textContaining('March 4, 2019'), findsOneWidget);
      expect(find.textContaining('March 5, 2019'), findsOneWidget);
    });

    testWidgets('Open conversation closes both with the token', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: c,
                    builder: (_) => SearchDialog(
                      search: (t, {token, cursor}) async =>
                          SearchPage([hit(1, token: 'room')], null, false),
                      context: (_, _) async => [msg(1, 'found')],
                      preview: (_) async => Uint8List(0),
                      selfId: 'me',
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await type(tester, 'x');
      await tester.tap(find.text('words'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      expect(result, 'room');
      expect(find.text('Search messages'), findsNothing);
    });

    testWidgets('a message that\'s gone says so and offers another try', (tester) async {
      var fail = true;
      await open(
        tester,
        search: (t, {token, cursor}) async => SearchPage([hit(1)], null, false),
        context: (_, _) async {
          if (fail) throw ApiException(404, 'p');
          return [msg(1, 'back again')];
        },
      )();
      await type(tester, 'x');
      await tester.tap(find.text('words'));
      await tester.pumpAndSettle();
      expect(find.textContaining('isn\'t available'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('back again', findRichText: true), findsWidgets);
    });

    testWidgets('neither dialog overflows in a short narrow window', (tester) async {
      tester.view.physicalSize = const Size(360, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(
        tester,
        search: (t, {token, cursor}) async => SearchPage([
          for (var i = 1; i < 8; i++) hit(i, text: 'a long excerpt ' * 12),
        ], null, true),
        context: (_, _) async => [
          for (var i = 1; i < 12; i++) msg(i, 'a long message ' * 20),
        ],
      )();
      await type(tester, 'x');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
