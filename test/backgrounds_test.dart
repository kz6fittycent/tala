import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/background_picker.dart';
import 'package:tala/src/backgrounds.dart';
import 'package:tala/src/settings.dart';

/// A small PNG drawn on the spot.
Future<Uint8List> png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Lets real file and decoding work finish, pumping frames between.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ids round trip, and an unknown one means none', () {
    for (final b in [
      CallBackground.none,
      CallBackground.blur,
      CallBackground.own,
      ...CallBackground.builtIn,
    ]) {
      expect(CallBackground.fromId(b.id), b);
    }
    expect(CallBackground.fromId('gone'), CallBackground.none);
    expect(CallBackground.fromId(null), CallBackground.none);
    expect(CallBackground.none.isPicture, isFalse);
    expect(CallBackground.blur.isPicture, isFalse);
    expect(CallBackground.own.isPicture, isTrue);
    expect(CallBackground.builtIn.every((b) => b.isPicture), isTrue);
  });

  test('every built-in picture and thumbnail ships', () {
    for (final b in CallBackground.builtIn) {
      expect(File(b.asset!).existsSync(), isTrue, reason: b.asset);
      expect(File(b.thumbnail!).existsSync(), isTrue, reason: b.thumbnail);
    }
  });

  test('pictures shrink to fit 1920x1080, keeping their shape', () {
    expect(backgroundSize(1280, 720), (1280, 720));
    expect(backgroundSize(3840, 2160), (1920, 1080));
    expect(backgroundSize(4000, 3000), (1440, 1080));
    expect(backgroundSize(1000, 4000), (270, 1080));
    expect(backgroundSize(6000, 1000), (1920, 320));
  });

  test('built-in pictures decode to RGBA at full size', () async {
    final p = await loadBackground(CallBackground.builtIn.first);
    expect(p, isNotNull);
    expect((p!.width, p.height), (1920, 1080));
    expect(p.rgba.length, 1920 * 1080 * 4);
    expect(await loadBackground(CallBackground.blur), isNull);
    expect(await loadBackground(CallBackground.none), isNull);
  });

  test('the user\'s own picture is kept as a copy, and junk is refused',
      () async {
    final dir = Directory.systemTemp.createTempSync('tala-bg');
    expect(await loadBackground(CallBackground.own, dir: dir), isNull);
    expect(
      await saveOwnBackground(Uint8List.fromList([1, 2, 3, 4]), dir: dir),
      isFalse,
    );
    expect(ownBackgroundFile(dir: dir).existsSync(), isFalse);
    expect(await saveOwnBackground(await png(40, 30), dir: dir), isTrue);
    final p = await loadBackground(CallBackground.own, dir: dir);
    expect((p!.width, p.height), (40, 30));
  });

  test('a blur setting from 0.8 carries over', () {
    final dir = Directory.systemTemp.createTempSync('tala-bg');
    final file = File('${dir.path}/settings.json')
      ..writeAsStringSync('{"blurBackground": true}');
    expect(AppSettings(file: file).callBackground, CallBackground.blur);
    file.writeAsStringSync('{"blurBackground": false}');
    expect(AppSettings(file: file).callBackground, CallBackground.none);
    file.writeAsStringSync('{"blurBackground": true, "callBackground": "hills"}');
    expect(AppSettings(file: file).callBackground.id, 'hills');
  });

  group('picker', () {
    Future<Future<CallBackground?>> show(
      WidgetTester tester,
      Directory dir, {
      CallBackground current = CallBackground.none,
      Future<Uint8List?> Function()? choose,
    }) async {
      late Future<CallBackground?> result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showBackgroundPicker(
              context,
              current,
              dir: dir,
              choosePicture: choose ?? () async => null,
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('choosing a tile returns it', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tala-bg');
      final result = await show(tester, dir);
      expect(find.text('Your picture'), findsNothing);
      expect(find.text('Add a picture…'), findsOneWidget);
      await tester.tap(find.text('Hills'));
      await tester.pumpAndSettle();
      expect((await result)?.id, 'hills');
    });

    testWidgets('Close returns nothing', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tala-bg');
      final result = await show(tester, dir, current: CallBackground.blur);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('adding a picture saves it and picks it', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tala-bg');
      final bytes = (await tester.runAsync(() => png(64, 36)))!;
      final result = await show(tester, dir, choose: () async => bytes);
      await tester.tap(find.text('Add a picture…'));
      await settle(tester);
      expect(await result, CallBackground.own);
      expect(ownBackgroundFile(dir: dir).readAsBytesSync(), bytes);
    });

    testWidgets('a file that isn\'t a picture says so', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tala-bg');
      await show(tester, dir,
          choose: () async => Uint8List.fromList([0, 1, 2]));
      await tester.tap(find.text('Add a picture…'));
      await settle(tester);
      expect(find.text('Tala couldn\'t read that picture.'), findsOneWidget);
      expect(ownBackgroundFile(dir: dir).existsSync(), isFalse);
    });

    testWidgets('a saved picture shows as its own choice', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tala-bg');
      ownBackgroundFile(dir: dir)
          .writeAsBytesSync((await tester.runAsync(() => png(64, 36)))!);
      final result = await show(tester, dir, current: CallBackground.own);
      expect(find.text('Change picture…'), findsOneWidget);
      await tester.tap(find.text('Your picture'));
      await tester.pumpAndSettle();
      expect(await result, CallBackground.own);
    });
  });
}
