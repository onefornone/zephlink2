import 'package:flutter/material.dart';

/// Always-bright green dot used on dark gradient surfaces.
const Color kOnlineDot = Color(0xFF7CF2B0);

/// Extra Zephlink colors that are not part of Flutter's ColorScheme.
extension ZephColors on ColorScheme {
  bool get isDarkScheme => brightness == Brightness.dark;

  /// Green used for "connected" dots on normal surfaces.
  Color get success =>
      isDarkScheme ? const Color(0xFF7CF2B0) : const Color(0xFF1E7A48);

  /// Warm yellow accent (the link nodes in the logo, the "Always on" badge).
  Color get amber => const Color(0xFFFFD66B);
  Color get onAmber => const Color(0xFF3A2A00);

  /// Gradient behind the connected-device card.
  List<Color> get heroGradient => isDarkScheme
      ? const [Color(0xFF006A87), Color(0xFF00303C)]
      : const [Color(0xFF00789A), Color(0xFF00455A)];

  /// Translucent chip on top of the gradient.
  Color get heroChip => Colors.white.withValues(alpha: 0.18);

  /// Dark stage used behind mirrored screens (same in light and dark).
  List<Color> get stageGradient =>
      const [Color(0xFF0B4F63), Color(0xFF00262F)];
}
