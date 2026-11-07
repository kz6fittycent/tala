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
            child: FillGrid(
              children: [for (final k in keys) SizedBox(key: k)],
            ),
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
}
