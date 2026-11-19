import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/call_layout.dart';

void main() {
  test('grid shapes', () {
    expect(gridShape(0), (0, 0));
    expect(gridShape(1), (1, 1));
    expect(gridShape(2), (2, 1));
    expect(gridShape(3), (2, 2));
    expect(gridShape(4), (2, 2));
    expect(gridShape(5), (3, 2));
    expect(gridShape(9), (3, 3));
    expect(gridShape(10), (4, 3));
  });

  Future<List<Rect>> layOut(WidgetTester tester, int count) async {
    final keys = [for (var i = 0; i < count; i++) GlobalKey()];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 800,
            height: 400,
            child: FillGrid(children: [for (final k in keys) SizedBox(key: k)]),
          ),
        ),
      ),
    );
    return [for (final k in keys) tester.getRect(find.byKey(k))];
  }

  testWidgets('one video gets the whole area', (tester) async {
    final rects = await layOut(tester, 1);
    expect(rects.single.size, const Size(800, 400));
  });

  testWidgets('two videos split it side by side', (tester) async {
    final rects = await layOut(tester, 2);
    expect(rects[0].size, const Size(400, 400));
    expect(rects[1].size, const Size(400, 400));
  });

  testWidgets('a short last row stretches, leaving no gap', (tester) async {
    final rects = await layOut(tester, 3);
    expect(rects[0].size, const Size(400, 200));
    expect(rects[1].size, const Size(400, 200));
    expect(rects[2].size, const Size(800, 200));
  });

  testWidgets('no videos draws nothing and does not throw', (tester) async {
    expect(await layOut(tester, 0), isEmpty);
    expect(tester.takeException(), isNull);
  });

  group('call layout', () {
    final others = GlobalKey();
    final self = GlobalKey();
    final controls = GlobalKey();
    final chat = GlobalKey();

    Future<void> show(
      WidgetTester tester,
      Size size, {
      bool withChat = true,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: CallLayout(
            others: SizedBox.expand(key: others),
            self: SizedBox.expand(key: self),
            controls: SizedBox(key: controls, height: 40),
            chat: withChat ? SizedBox.expand(key: chat) : null,
          ),
        ),
      );
    }

    Rect at(WidgetTester tester, GlobalKey key) =>
        tester.getRect(find.byKey(key));

    testWidgets('without chat, the other person fills everything', (
      tester,
    ) async {
      await show(tester, const Size(1200, 800), withChat: false);
      expect(at(tester, others), const Rect.fromLTWH(0, 0, 1200, 800));
      expect(at(tester, self), const Rect.fromLTWH(944, 16, 240, 135));
      expect(find.byKey(chat), findsNothing);
    });

    testWidgets('wide: own camera sits above chat, beside the video', (
      tester,
    ) async {
      await show(tester, const Size(1200, 800));
      expect(at(tester, others), const Rect.fromLTWH(0, 0, 860, 800));
      final mine = at(tester, self);
      expect(mine.left, 860);
      expect(mine.top, 0);
      expect(mine.width, 340);
      final talk = at(tester, chat);
      expect(talk.left, 860);
      expect(talk.top, mine.bottom);
      expect(talk.bottom, 800);
      expect(at(tester, controls).center.dx, 430);
    });

    testWidgets('narrow: chat goes under the video', (tester) async {
      await show(tester, const Size(600, 800));
      final video = at(tester, others);
      final talk = at(tester, chat);
      expect(video.width, 600);
      expect(talk.width, 600);
      expect(talk.top, video.bottom);
      expect(at(tester, self).width, 128);
    });
  });

  group('shared screen', () {
    Future<void> show(
      WidgetTester tester, {
      int screens = 1,
      int people = 2,
    }) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenStage(
            screens: [
              for (var i = 0; i < screens; i++)
                SizedBox(key: ValueKey('screen $i')),
            ],
            people: [
              for (var i = 0; i < people; i++)
                StageTile(
                  id: 'p$i',
                  video: SizedBox(key: ValueKey('person $i')),
                ),
            ],
          ),
        ),
      );
    }

    testWidgets('takes the space, with people in a row below', (tester) async {
      await show(tester);
      final screen = tester.getRect(find.byKey(const ValueKey('screen 0')));
      final person = tester.getRect(find.byKey(const ValueKey('person 0')));
      expect(screen.width, 1000);
      expect(screen.height, 700 - screenStripHeight - screenControlsSpace);
      expect(person.top, greaterThanOrEqualTo(screen.bottom));
      expect(person.bottom, lessThanOrEqualTo(700 - screenControlsSpace));
      expect(person.width / person.height, closeTo(16 / 9, 0.01));
    });

    testWidgets('alone, a screen gets everything above the controls', (
      tester,
    ) async {
      await show(tester, people: 0);
      final screen = tester.getRect(find.byKey(const ValueKey('screen 0')));
      expect(screen.height, 700 - screenControlsSpace);
    });

    testWidgets('with no screen, people fill the space as before', (
      tester,
    ) async {
      await show(tester, screens: 0, people: 1);
      expect(
        tester.getRect(find.byKey(const ValueKey('person 0'))).size,
        const Size(1000, 700),
      );
    });

    testWidgets('many people scroll rather than overflow', (tester) async {
      await show(tester, people: 12);
      expect(tester.takeException(), isNull);
    });
  });
  group('sharing banner', () {
    testWidgets('fits a narrow window and stops when asked', (tester) async {
      tester.view.physicalSize = const Size(320, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var stopped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SharingBanner(onStop: () => stopped++)),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Stop sharing'));
      expect(stopped, 1);
    });
  });

  group('views', () {
    List<StageTile> tiles(int n, {String? speaking}) => [
      for (var i = 0; i < n; i++)
        StageTile(
          id: 'p$i',
          name: 'Person $i',
          speaking: 'p$i' == speaking,
          video: SizedBox.expand(key: ValueKey('video $i')),
        ),
    ];

    Future<void> show(
      WidgetTester tester,
      Widget child, {
      Size size = const Size(1000, 700),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    }

    Rect video(WidgetTester tester, int i) =>
        tester.getRect(find.byKey(ValueKey('video $i')));

    test('focus goes to the pinned, then the speaker, then the first', () {
      final people = tiles(3);
      expect(focusOf(people, pinned: 'p2', speaker: 'p1'), 'p2');
      expect(focusOf(people, pinned: 'gone', speaker: 'p1'), 'p1');
      expect(focusOf(people, speaker: 'gone'), 'p0');
      expect(focusOf(const []), isNull);
    });

    testWidgets('speaker view: the speaker large, the rest in a row', (
      tester,
    ) async {
      await show(
        tester,
        PeopleStage(
          people: tiles(3, speaking: 'p1'),
          view: PeopleView.speaker,
          speaker: 'p1',
        ),
      );
      final big = video(tester, 1);
      expect(big.width, 1000);
      expect(big.height, 700 - screenStripHeight - screenControlsSpace);
      for (final i in [0, 2]) {
        final small = video(tester, i);
        expect(small.top, greaterThanOrEqualTo(big.bottom));
        expect(small.width / small.height, closeTo(16 / 9, 0.01));
      }
      // The large one isn't framed; it's plain who it is.
      expect(find.byKey(const ValueKey('speaking')), findsNothing);
      expect(find.text('Person 1'), findsOneWidget);
    });

    testWidgets('speaker view with one other person is just them', (
      tester,
    ) async {
      await show(
        tester,
        PeopleStage(people: tiles(1), view: PeopleView.speaker),
      );
      expect(video(tester, 0).size, const Size(1000, 700));
    });

    testWidgets('tapping someone in the row pins them, tapping again lets go',
        (tester) async {
      String? pinned;
      await show(
        tester,
        StatefulBuilder(
          builder: (context, setState) => PeopleStage(
            people: tiles(3),
            view: PeopleView.speaker,
            speaker: 'p0',
            pinned: pinned,
            onPin: (id) => setState(() => pinned = id),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('video 2')));
      await tester.pumpAndSettle();
      expect(pinned, 'p2');
      expect(video(tester, 2).width, 1000);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video 2')));
      await tester.pumpAndSettle();
      expect(pinned, isNull);
      expect(video(tester, 0).width, 1000);
    });

    testWidgets('grid view: everyone the same, the speaker framed', (
      tester,
    ) async {
      await show(
        tester,
        PeopleStage(people: tiles(4, speaking: 'p3'), view: PeopleView.grid),
      );
      expect(video(tester, 0).size, const Size(500, 350));
      expect(video(tester, 3).size, const Size(500, 350));
      expect(find.byKey(const ValueKey('speaking')), findsOneWidget);
    });

    testWidgets('people beside a shared screen', (tester) async {
      await show(
        tester,
        ScreenStage(
          screens: const [SizedBox.expand(key: ValueKey('screen'))],
          people: tiles(2),
          screenView: ScreenView.beside,
        ),
      );
      final screen = tester.getRect(find.byKey(const ValueKey('screen')));
      expect(screen.width, 1000 - screenColumnWidth);
      expect(screen.height, 700 - screenControlsSpace);
      expect(video(tester, 0).left, greaterThanOrEqualTo(screen.right));
      expect(video(tester, 1).top, greaterThan(video(tester, 0).top));
    });

    testWidgets('beside a screen, own video heads the column', (tester) async {
      const screens = [SizedBox.expand(key: ValueKey('screen'))];
      final people = tiles(2);
      expect(ScreenStage.holdsSelf(screens, people, ScreenView.beside), isTrue);
      expect(ScreenStage.holdsSelf(screens, people, ScreenView.below), isFalse);
      expect(ScreenStage.holdsSelf(const [], people, ScreenView.beside),
          isFalse);
      await show(
        tester,
        ScreenStage(
          screens: screens,
          people: people,
          screenView: ScreenView.beside,
          self: const SizedBox.expand(key: ValueKey('self')),
        ),
      );
      final self = tester.getRect(find.byKey(const ValueKey('self')));
      expect(self.left, 1000 - screenColumnWidth + 4);
      expect(self.top, lessThan(video(tester, 0).top));
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('screen only leaves people out', (tester) async {
      await show(
        tester,
        ScreenStage(
          screens: const [SizedBox.expand(key: ValueKey('screen'))],
          people: tiles(2),
          screenView: ScreenView.only,
        ),
      );
      final screen = tester.getRect(find.byKey(const ValueKey('screen')));
      expect(screen.size, const Size(1000, 700 - screenControlsSpace));
      expect(find.byKey(const ValueKey('video 0')), findsNothing);
    });

    testWidgets('views are stored by name, unknown ones fall back', (
      tester,
    ) async {
      expect(PeopleView.fromName('speaker'), PeopleView.speaker);
      expect(PeopleView.fromName('nonsense'), PeopleView.grid);
      expect(ScreenView.fromName('only'), ScreenView.only);
      expect(ScreenView.fromName(null), ScreenView.below);
    });
  });

  group('own video hidden', () {
    final others = GlobalKey();
    final chat = GlobalKey();

    Future<void> show(WidgetTester tester, Size size, {bool withChat = true})
        async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: CallLayout(
            others: SizedBox.expand(key: others),
            self: null,
            controls: const SizedBox(height: 40),
            chat: withChat ? SizedBox.expand(key: chat) : null,
          ),
        ),
      );
    }

    testWidgets('wide: the chat takes the whole column', (tester) async {
      await show(tester, const Size(1200, 800));
      expect(tester.getRect(find.byKey(chat)),
          const Rect.fromLTWH(860, 0, 340, 800));
    });

    testWidgets('narrow and without chat, nothing floats in the corner', (
      tester,
    ) async {
      await show(tester, const Size(600, 800));
      expect(tester.takeException(), isNull);
      await show(tester, const Size(1200, 800), withChat: false);
      expect(tester.getRect(find.byKey(others)),
          const Rect.fromLTWH(0, 0, 1200, 800));
    });
  });
}
