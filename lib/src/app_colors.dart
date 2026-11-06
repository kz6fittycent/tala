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

/// The fidelity variant stays on the accent's hue. The default one tints a blue
/// app's secondary colors purple.
ThemeData talaTheme(Accent accent, Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: accent.color,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ),
  extensions: [AvatarColors(accent.color)],
);
