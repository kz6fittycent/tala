import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart';
import 'package:tala/src/chat_view.dart';
import 'package:tala/src/giphy.dart';
import 'package:tala/src/nc_api.dart' show Room;

import 'chat_test.dart' show FakeSource, msg, testDrafts;

/// A 1x1 GIF.
final _pixel = base64.decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

const _base = 'https://cloud.example/index.php/apps/integration_giphy';

Map<String, dynamic> entry(String id) => {
  'thumbnailUrl':
      '$_base/gif/direct/$id/media2/200w.gif/abc/200w.gif/g',
  'title': 'Cat $id',
  'resourceUrl': 'https://giphy.com/gifs/cat-$id',
};

class FakeGifs {
  GifSupport support = GifSupport.ready;
  final List<String> searches = [];
  final List<String> media = [];
  final List<String> links = [];
  Object? error;
  int perPage = 3;

  GifSource get source => GifSource(
    support: () async => support,
    search: (term, cursor) async {
      searches.add('$term@$cursor');
      final e = error;
      if (e != null) throw e;
      return GifPage.fromJson({
        'entries': [
          for (var i = 0; i < perPage; i++) entry('${term}x${cursor + i}'),
        ],
        'cursor': cursor + perPage,
      }, cursor);
    },
    media: (path) async {
      media.add(path);
      return _pixel;
    },
    forLink: (link) async {
      links.add(link);
      return _pixel;
    },
  );
}

void main() {
  group('the command', () {
    test('only a whole message starting with /giphy or /gif', () {
      expect(gifCommandTerm('/giphy cats'), 'cats');
      expect(gifCommandTerm('/gif  happy dance '), 'happy dance');
      expect(gifCommandTerm('/giphy'), '');
      expect(gifCommandTerm('/gif '), '');
      expect(gifCommandTerm('/gifts'), isNull);
      expect(gifCommandTerm('see /giphy cats'), isNull);
      expect(gifCommandTerm('/giphy cats\nand more'), isNull);
    });
  });

  group('links and pictures', () {
    test('giphy links are the ones the server previews', () {
      expect(isGiphyLink('https://giphy.com/gifs/seal-sappy-BaDsH4Fp'), isTrue);
      expect(
        isGiphyLink('https://media.giphy.com/media/BaDsH4Fp/giphy.gif'),
        isTrue,
      );
      expect(isGiphyLink('https://giphy.com/gifs/x/y'), isFalse);
      expect(isGiphyLink('https://evil.example/giphy.com/gifs/x'), isFalse);
    });

    test('pictures are only fetched from the Giphy app\'s route, rebuilt on '
        'the signed-in server', () {
      expect(
        giphyMediaPath('$_base/gif/direct/ID/media2/200w.gif/c/r/g'),
        '/index.php/apps/integration_giphy/gif/direct/ID/media2/200w.gif/c/r/g',
      );
      // Another host, a web root, or the private variant: same path here.
      expect(
        giphyMediaPath(
          'http://localhost/nc/index.php/apps/integration_giphy/private/gif/'
          'direct/ID/media2/200w.gif/c/r/g',
        ),
        '/index.php/apps/integration_giphy/gif/direct/ID/media2/200w.gif/c/r/g',
      );
      expect(giphyMediaPath('$_base/admin-config'), isNull);
      expect(giphyMediaPath('$_base/gif/direct/ID/../../x/c/r/g'), isNull);
      expect(giphyMediaPath('https://media.giphy.com/media/x/giphy.gif'), isNull);
      expect(giphyMediaPath(7), isNull);
    });

    test('the WebP copy keeps everything but the file type', () {
      expect(
        webpPath(
          '/index.php/apps/integration_giphy/gif/direct/ID/media4/200w.gif/C/200w.gif/g',
        ),
        '/index.php/apps/integration_giphy/gif/direct/ID/media4/200w.webp/C/200w.webp/g',
      );
      expect(
        webpPath(
          '/index.php/apps/integration_giphy/gif/direct/ID/media4/200w.mp4/C/200w.mp4/g',
        ),
        isNull,
      );
    });

    test('a resolved link asks for the small version', () {
      expect(
        gifPathFromRichObject({
          'id': 'ID',
          'images': {
            'fixed_width': {
              'url':
                  'https://media4.giphy.com/media/ID/200w.gif?cid=C&rid=200w.gif&ct=g',
            },
          },
          'proxied_url': '$_base/gif/direct/ID/media4/giphy.gif/C/giphy.gif/g',
        }),
        '/index.php/apps/integration_giphy/gif/direct/ID/media4/200w.gif/C/200w.gif/g',
      );
      expect(
        gifPathFromRichObject({
          'id': 'ID',
          'images': {
            'fixed_width': {
              'url': 'https://media1.giphy.com/media/v1.Y2lk/ID/200w.gif',
            },
          },
        }),
        '/index.php/apps/integration_giphy/gif/direct/ID/media1/200w.gif/cid/200w.gif/g',
      );
      // Without a readable small version, the app's own full-size address.
      expect(
        gifPathFromRichObject({
          'id': 'ID',
          'proxied_url': '$_base/gif/direct/ID/media4/giphy.gif/C/giphy.gif/g',
        }),
        '/index.php/apps/integration_giphy/gif/direct/ID/media4/giphy.gif/C/giphy.gif/g',
      );
      expect(gifPathFromRichObject({'id': 'ID'}), isNull);
    });

    test('a page drops entries it can\'t use and knows when there\'s more', () {
      final page = GifPage.fromJson({
        'entries': [
          entry('a'),
          {...entry('b'), 'thumbnailUrl': 'https://media.giphy.com/x.gif'},
          {...entry('c'), 'resourceUrl': 'https://elsewhere.example/c'},
        ],
        'cursor': 3,
      }, 0);
      expect(page.gifs.map((g) => g.link), ['https://giphy.com/gifs/cat-a']);
      expect(page.next, 3);
      expect(page.more, isFalse);
    });
  });

  group('in a conversation', () {
    final room = Room(
      't',
      'Family',
      false,
      2,
      canChat: true,
      selfId: 'me',
      lastRead: 1,
    );

    Widget pane(FakeSource src, FakeGifs gifs) => MaterialApp(
      home: Scaffold(
        body: ConversationPane(
          source: src,
          room: room,
          drafts: testDrafts(),
          gifs: gifs.source,
          onBack: () {},
          onCall: () {},
        ),
      ),
    );

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
    }

    testWidgets('/giphy searches after a pause, and Enter sends the picked '
        'GIF\'s link instead of the command', (tester) async {
      final src = FakeSource()..history = ((_) => [msg(1)]);
      final gifs = FakeGifs();
      await tester.pumpWidget(pane(src, gifs));
      await tester.pump();

      await type(tester, '/giphy');
      expect(find.text('Trending GIFs'), findsOneWidget);
      expect(find.text('Powered by GIPHY'), findsOneWidget);
      expect(gifs.searches, ['@0']);

      await tester.enterText(find.byType(TextField), '/giphy c');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), '/giphy cat');
      await tester.pump(const Duration(milliseconds: 100));
      // Still typing: Enter must not send a GIF for older text.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(src.sentTexts, isEmpty);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(gifs.searches, ['@0', 'cat@0']);
      expect(find.text('GIFs for "cat"'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(src.sentTexts, ['https://giphy.com/gifs/cat-catx1']);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
      expect(find.text('GIFs for "cat"'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Escape closes the panel and then the text sends as typed',
        (tester) async {
      final src = FakeSource()..history = ((_) => [msg(1)]);
      final gifs = FakeGifs();
      await tester.pumpWidget(pane(src, gifs));
      await tester.pump();
      await type(tester, '/gif dog');
      expect(find.text('GIFs for "dog"'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('GIFs for "dog"'), findsNothing);
      await type(tester, '/gif dogs');
      expect(find.text('GIFs for "dogs"'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(src.sentTexts, ['/gif dogs']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('says what\'s wrong: no key yet, or Giphy\'s hourly limit',
        (tester) async {
      final src = FakeSource()..history = ((_) => [msg(1)]);
      final gifs = FakeGifs()..support = GifSupport.unconfigured;
      await tester.pumpWidget(pane(src, gifs));
      await tester.pump();
      await type(tester, '/giphy cat');
      expect(find.textContaining('isn\'t set up yet'), findsOneWidget);
      expect(gifs.searches, isEmpty);
      await tester.pumpWidget(const SizedBox());

      final limited = FakeGifs()..error = ApiException(429, 'x');
      await tester.pumpWidget(pane(src, limited));
      await tester.pump();
      await type(tester, '/giphy cat');
      expect(find.textContaining('busy'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the Giphy app, /giphy is just text', (tester) async {
      final src = FakeSource()..history = ((_) => [msg(1)]);
      final gifs = FakeGifs()..support = GifSupport.none;
      await tester.pumpWidget(pane(src, gifs));
      await tester.pump();
      await type(tester, '/giphy cat');
      expect(find.text('GIFs for "cat"'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(src.sentTexts, ['/giphy cat']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a giphy link in a message is fetched to play, other links '
        'aren\'t', (tester) async {
      const link = 'https://giphy.com/gifs/seal-BaDsH4Fp';
      ChatMessage linkMessage(int id, String url) => ChatMessage(
        id: id,
        actorType: 'users',
        actorId: 'bob',
        actorName: 'Bob',
        timestamp: 1000 + id,
        segments: [Segment(url, SegmentKind.link, url)],
      );
      final src = FakeSource()
        ..history = ((_) => [
          linkMessage(1, link),
          linkMessage(2, 'https://example.com/page'),
        ]);
      final gifs = FakeGifs();
      await tester.pumpWidget(pane(src, gifs));
      await tester.pump();
      await tester.pump();
      expect(gifs.links, [link]);
      expect(
        find.byWidgetPredicate(
          (w) => w is Image && w.image is MemoryImage &&
              listEquals((w.image as MemoryImage).bytes, _pixel),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}

bool listEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

