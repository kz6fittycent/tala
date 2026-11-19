// The call screen for tool/make_screenshots.dart. Real video can't be drawn
// in a test, so each person is a simple painted figure in a painted room, and
// a shared screen is a painted slide: nobody real appears.
import 'package:flutter/material.dart';
import 'package:tala/src/call_controls.dart';
import 'package:tala/src/call_layout.dart';
import 'package:tala/src/settings.dart';

/// How one painted person looks.
class Figure {
  const Figure({
    required this.wall,
    required this.skin,
    required this.hair,
    required this.shirt,
    this.longHair = false,
    this.shelf = false,
    this.plant = false,
    this.lamp = false,
  });
  final Color wall, skin, hair, shirt;
  final bool longHair, shelf, plant, lamp;
}

const figures = <String, Figure>{
  'Maya Chen': Figure(
    wall: Color(0xFFB9C9D6),
    skin: Color(0xFFE8C2A0),
    hair: Color(0xFF2B2522),
    shirt: Color(0xFF2E6F95),
    longHair: true,
    shelf: true,
  ),
  'Daniel Ortiz': Figure(
    wall: Color(0xFFD8C8B0),
    skin: Color(0xFFB98563),
    hair: Color(0xFF1E1A18),
    shirt: Color(0xFF6B8F4E),
    plant: true,
  ),
  'Sam Rivers': Figure(
    wall: Color(0xFF9FB3A0),
    skin: Color(0xFFF1D0B5),
    hair: Color(0xFFB0753E),
    shirt: Color(0xFF8C4A5B),
    lamp: true,
  ),
  'Priya Nair': Figure(
    wall: Color(0xFFCFB9C9),
    skin: Color(0xFF9C6B4E),
    hair: Color(0xFF151212),
    shirt: Color(0xFFD9A441),
    longHair: true,
    plant: true,
  ),
  'You': Figure(
    wall: Color(0xFF8E9AA8),
    skin: Color(0xFFD9AE8C),
    hair: Color(0xFF4A3426),
    shirt: Color(0xFF3B4A5A),
    shelf: true,
  ),
};

/// A painted person, filling its space as a cropped camera picture would.
class FigureVideo extends StatelessWidget {
  const FigureVideo(this.figure, {super.key});
  final Figure figure;

  @override
  Widget build(BuildContext context) =>
      ClipRect(child: CustomPaint(painter: _FigurePainter(figure)));
}

class _FigurePainter extends CustomPainter {
  _FigurePainter(this.f);
  final Figure f;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [f.wall, Color.lerp(f.wall, Colors.black, 0.25)!],
        ).createShader(rect),
    );
    // Everything is laid out on the height, centered, like a cropped camera.
    final h = size.height;
    final cx = size.width / 2;
    final paint = Paint();
    if (f.shelf) {
      paint.color = Color.lerp(f.wall, Colors.brown, 0.6)!;
      final shelf = Rect.fromLTWH(cx - h * 0.95, h * 0.30, h * 0.5, h * 0.035);
      canvas.drawRect(shelf, paint);
      const books = [
        Color(0xFF7A3E3E),
        Color(0xFF3E5A7A),
        Color(0xFFC2A04A),
        Color(0xFF4F6F52),
      ];
      var x = shelf.left + h * 0.03;
      for (var i = 0; i < books.length; i++) {
        final bh = h * (0.12 + 0.02 * (i % 2));
        paint.color = books[i];
        canvas.drawRect(Rect.fromLTWH(x, shelf.top - bh, h * 0.045, bh), paint);
        x += h * 0.06;
      }
    }
    if (f.plant) {
      final base = Offset(cx + h * 0.62, h * 0.82);
      paint.color = const Color(0xFF8B5A3C);
      canvas.drawRect(
        Rect.fromCenter(center: base, width: h * 0.14, height: h * 0.14),
        paint,
      );
      paint.color = const Color(0xFF3F7A4A);
      for (var i = -2; i <= 2; i++) {
        canvas.drawOval(
          Rect.fromCenter(
            center: base.translate(i * h * 0.05, -h * (0.16 + 0.04 * (2 - i.abs()))),
            width: h * 0.08,
            height: h * 0.2,
          ),
          paint,
        );
      }
    }
    if (f.lamp) {
      final glow = Offset(cx - h * 0.6, h * 0.25);
      canvas.drawCircle(
        glow,
        h * 0.35,
        Paint()
          ..shader = RadialGradient(
            colors: [const Color(0x66FFF3C4), const Color(0x00FFF3C4)],
          ).createShader(Rect.fromCircle(center: glow, radius: h * 0.35)),
      );
      paint.color = const Color(0xFFEEE2C0);
      canvas.drawPath(
        Path()
          ..moveTo(glow.dx - h * 0.08, glow.dy + h * 0.05)
          ..lineTo(glow.dx + h * 0.08, glow.dy + h * 0.05)
          ..lineTo(glow.dx + h * 0.05, glow.dy - h * 0.06)
          ..lineTo(glow.dx - h * 0.05, glow.dy - h * 0.06)
          ..close(),
        paint,
      );
    }
    // Long hair falls behind the shoulders.
    if (f.longHair) {
      paint.color = f.hair;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - h * 0.17, h * 0.22, h * 0.34, h * 0.42),
          Radius.circular(h * 0.12),
        ),
        paint,
      );
    }
    // Shoulders and neck.
    paint.color = f.shirt;
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(cx - h * 0.36, h * 0.70, h * 0.72, h * 0.40),
        topLeft: Radius.circular(h * 0.16),
        topRight: Radius.circular(h * 0.16),
      ),
      paint,
    );
    paint.color = Color.lerp(f.skin, Colors.black, 0.08)!;
    canvas.drawRect(
      Rect.fromLTWH(cx - h * 0.065, h * 0.52, h * 0.13, h * 0.2),
      paint,
    );
    // Head, then hair on top.
    paint.color = f.skin;
    final head = Rect.fromCenter(
      center: Offset(cx, h * 0.42),
      width: h * 0.27,
      height: h * 0.33,
    );
    canvas.drawOval(head, paint);
    paint.color = f.hair;
    canvas.drawArc(
      head.inflate(h * 0.012).translate(0, -h * 0.012),
      3.4,
      2.62,
      false,
      paint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, head.top + h * 0.035),
        width: head.width * 0.95,
        height: h * 0.09,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_FigurePainter old) => old.f != f;
}

/// A painted slide about the hike, standing in for a shared screen.
class SlideVideo extends StatelessWidget {
  const SlideVideo({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: CustomPaint(painter: _SlidePainter()),
    ),
  );
}

class _SlidePainter extends CustomPainter {
  void _text(Canvas canvas, String s, Offset at, double size, Color color,
      {FontWeight weight = FontWeight.normal}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          color: color,
          fontWeight: weight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF7F5F0));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h * 0.16),
      Paint()..color = const Color(0xFF2F5D50),
    );
    _text(canvas, "Saturday's route", Offset(w * 0.05, h * 0.04), h * 0.07,
        Colors.white, weight: FontWeight.bold);
    const stops = [
      'Trailhead parking, 8:00',
      'Falls overlook, 9:30',
      'Lunch at the lake, 12:00',
      'Back at the cars by 4',
    ];
    for (var i = 0; i < stops.length; i++) {
      final y = h * (0.26 + i * 0.12);
      canvas.drawCircle(Offset(w * 0.07, y + h * 0.03), h * 0.015,
          Paint()..color = const Color(0xFF2F5D50));
      _text(canvas, stops[i], Offset(w * 0.1, y), h * 0.05,
          const Color(0xFF333333));
    }
    // An elevation profile.
    final chart = Rect.fromLTWH(w * 0.52, h * 0.26, w * 0.43, h * 0.6);
    canvas.drawRect(chart, Paint()..color = const Color(0xFFE6EEE9));
    const heights = [0.15, 0.3, 0.55, 0.8, 0.7, 0.45, 0.5, 0.35, 0.2, 0.1];
    final path = Path()..moveTo(chart.left, chart.bottom);
    for (var i = 0; i < heights.length; i++) {
      path.lineTo(
        chart.left + chart.width * i / (heights.length - 1),
        chart.bottom - chart.height * heights[i] * 0.9,
      );
    }
    path
      ..lineTo(chart.right, chart.bottom)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF6E9B83));
    _text(canvas, 'Elevation', chart.topLeft.translate(h * 0.02, h * 0.02),
        h * 0.04, const Color(0xFF2F5D50));
  }

  @override
  bool shouldRepaint(_SlidePainter old) => false;
}

/// A tile for [name], speaking or not.
StageTile figureTile(String name, {bool speaking = false}) => StageTile(
  id: name,
  name: name,
  speaking: speaking,
  video: FigureVideo(figures[name]!),
);

/// The call screen as Tala draws it, around painted people.
Widget callScreen({
  required String title,
  required AppSettings settings,
  required List<StageTile> people,
  Widget? chat,
  List<Widget> screens = const [],
  String? speaker,
  String? pinned,
  bool sharing = false,
  bool noiseCancel = false,
  bool effectsOn = false,
  int unread = 0,
}) {
  final self = settings.callHideSelf ? null : FigureVideo(figures['You']!);
  return Scaffold(
  backgroundColor: Colors.black,
  appBar: AppBar(title: Text(title)),
  body: Column(
    children: [
      if (sharing) SharingBanner(onStop: () {}),
      Expanded(
        child: CallLayout(
          others: ScreenStage(
            self: ScreenStage.holdsSelf(screens, people, settings.callScreenView)
                ? self
                : null,
            screens: screens,
            people: people,
            peopleView: settings.callPeopleView,
            screenView: settings.callScreenView,
            speaker: speaker,
            pinned: pinned,
          ),
          self: ScreenStage.holdsSelf(screens, people, settings.callScreenView)
              ? null
              : self,
          chat: settings.callChatOpen ? chat : null,
          controls: CallControls(
            settings: settings,
            micOn: true,
            noiseCancel: noiseCancel,
            camOn: true,
            effectsOn: effectsOn,
            sharing: sharing,
            choosingScreen: false,
            unread: ValueNotifier(unread),
            onMic: () {},
            onNoiseCancel: () {},
            onCamera: () {},
            onBackground: () {},
            onScreen: () {},
            onViewChanged: () {},
            onChat: () {},
            onHangUp: () {},
          ),
        ),
      ),
    ],
  ),
);
}
