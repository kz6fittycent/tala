import 'package:flutter/material.dart';

/// The icon's blue, and the default accent.
const talaBlue = Color(0xFF0082C9);

class Accent {
  const Accent(this.name, this.label, this.color);

  /// Stored in settings, so it must not change.
  final String name;
  final String label;
  final Color color;
}

/// Fixed colors rather than the system's, so Tala looks the same everywhere.
/// Each is dark enough for white letters on an avatar, and tested for that.
const accents = [
  Accent('blue', 'Blue', talaBlue),
  Accent('teal', 'Teal', Color(0xFF00796B)),
  Accent('green', 'Green', Color(0xFF2E7D32)),
  Accent('amber', 'Amber', Color(0xFF8A6100)),
  Accent('rose', 'Rose', Color(0xFFBE185D)),
  Accent('slate', 'Slate', Color(0xFF475569)),
];

Accent accentNamed(String? name) =>
    accents.firstWhere((a) => a.name == name, orElse: () => accents.first);

/// The exact accent, for things that should match it rather than the tones the
/// color scheme derives from it.
class AvatarColors extends ThemeExtension<AvatarColors> {
  const AvatarColors(this.background);
  final Color background;

  @override
  AvatarColors copyWith({Color? background}) =>
      AvatarColors(background ?? this.background);

  @override
  AvatarColors lerp(ThemeExtension<AvatarColors>? other, double t) =>
      other is AvatarColors
      ? AvatarColors(Color.lerp(background, other.background, t)!)
      : this;
}

/// Backgrounds as lightness steps. The stock ones run from nearly black to
/// nearly white, which is harsh on the eyes either way. These are soft grays
/// with a trace of the accent's hue.
const _darkLevels = (
  dim: .13,
  surface: .15,
  lowest: .12,
  low: .17,
  container: .19,
  high: .22,
  highest: .26,
  bright: .28,
);
const _lightLevels = (
  dim: .80,
  surface: .89,
  lowest: .92,
  low: .90,
  container: .87,
  high: .85,
  highest: .82,
  bright: .92,
);

ColorScheme _softened(ColorScheme s, Accent accent) {
  final dark = s.brightness == Brightness.dark;
  final levels = dark ? _darkLevels : _lightLevels;
  final hue = HSLColor.fromColor(accent.color).hue;
  Color gray(double lightness) =>
      HSLColor.fromAHSL(1, hue, dark ? .07 : .10, lightness).toColor();
  // Own message bubbles. Their text uses the normal text color, which the
  // fidelity variant's saturated container is too close to.
  final bubble = HSLColor.fromAHSL(
    1,
    hue,
    dark ? .40 : .55,
    dark ? .27 : .78,
  ).toColor();
  // Selected rows have to stand out from the softer list behind them.
  final selection = HSLColor.fromAHSL(
    1,
    hue,
    dark ? .22 : .35,
    dark ? .25 : .79,
  ).toColor();
  return s.copyWith(
    primaryContainer: bubble,
    onPrimaryContainer: s.onSurface,
    secondaryContainer: selection,
    onSecondaryContainer: s.onSurface,
    surface: gray(levels.surface),
    surfaceDim: gray(levels.dim),
    surfaceBright: gray(levels.bright),
    surfaceContainerLowest: gray(levels.lowest),
    surfaceContainerLow: gray(levels.low),
    surfaceContainer: gray(levels.container),
    surfaceContainerHigh: gray(levels.high),
    surfaceContainerHighest: gray(levels.highest),
  );
}

/// The fidelity variant stays on the accent's hue. The default one tints a blue
/// app's secondary colors purple.
ThemeData talaTheme(Accent accent, Brightness brightness) => ThemeData(
  colorScheme: _softened(
    ColorScheme.fromSeed(
      seedColor: accent.color,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ),
    accent,
  ),
  extensions: [AvatarColors(accent.color)],
);
