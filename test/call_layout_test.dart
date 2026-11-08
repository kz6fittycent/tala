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
                SizedBox(key: ValueKey('person $i')),
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
}
