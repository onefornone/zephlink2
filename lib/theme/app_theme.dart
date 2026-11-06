import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Zephlink's Material 3 themes: one light, one dark.
class AppTheme {
  AppTheme._();

  /// Tests switch this off so they do not try to download fonts.
  static bool useGoogleFonts = true;

  static ThemeData light() => _build(_lightScheme);
  static ThemeData dark() => _build(_darkScheme);

  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF00677F),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFBFEBFA),
    onPrimaryContainer: Color(0xFF00262F),
    secondary: Color(0xFF4A6572),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFD2E6EE),
    onSecondaryContainer: Color(0xFF0B1F28),
    tertiary: Color(0xFF7A5900),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFFFE9A8),
    onTertiaryContainer: Color(0xFF3A2A00),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    surface: Color(0xFFF3F9FB),
    onSurface: Color(0xFF0F1B20),
    onSurfaceVariant: Color(0xFF3F5058),
    outline: Color(0xFF70787D),
    outlineVariant: Color(0xFFA9BEC7),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFEEF5F8),
    surfaceContainer: Color(0xFFE6F0F4),
    surfaceContainerHigh: Color(0xFFDCE9EE),
    surfaceContainerHighest: Color(0xFFD1E1E8),
  );

  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF6DD3EE),
    onPrimary: Color(0xFF00262F),
    primaryContainer: Color(0xFF004E63),
    onPrimaryContainer: Color(0xFFBFEBFA),
    secondary: Color(0xFFB4CAD4),
    onSecondary: Color(0xFF1E333C),
    secondaryContainer: Color(0xFF2C4A56),
    onSecondaryContainer: Color(0xFFD2E6EE),
    tertiary: Color(0xFFFFD66B),
    onTertiary: Color(0xFF3A2A00),
    tertiaryContainer: Color(0xFF574000),
    onTertiaryContainer: Color(0xFFFFE9A8),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Color(0xFF0B1418),
    onSurface: Color(0xFFE1EAEE),
    onSurfaceVariant: Color(0xFFA9BEC7),
    outline: Color(0xFF6B7F88),
    outlineVariant: Color(0xFF2C3E46),
    surfaceContainerLowest: Color(0xFF070E11),
    surfaceContainerLow: Color(0xFF111C21),
    surfaceContainer: Color(0xFF162329),
    surfaceContainerHigh: Color(0xFF1E2D34),
    surfaceContainerHighest: Color(0xFF28383F),
  );

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final TextTheme text =
        useGoogleFonts ? _withFonts(base.textTheme) : base.textTheme;

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primaryContainer,
        height: 80,
        labelTextStyle: WidgetStatePropertyAll(
          text.labelMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        space: 1,
        thickness: 1,
      ),
    );
  }

  /// DM Sans for text, Sora for headings.
  static TextTheme _withFonts(TextTheme base) {
    final body = GoogleFonts.dmSansTextTheme(base);
    TextStyle? sora(TextStyle? style, FontWeight weight) {
      return GoogleFonts.sora(textStyle: style, fontWeight: weight);
    }

    return body.copyWith(
      headlineLarge: sora(body.headlineLarge, FontWeight.w700),
      headlineMedium: sora(body.headlineMedium, FontWeight.w700),
      headlineSmall: sora(body.headlineSmall, FontWeight.w700),
      titleLarge: sora(body.titleLarge, FontWeight.w700),
      titleMedium: sora(body.titleMedium, FontWeight.w600),
      titleSmall: sora(body.titleSmall, FontWeight.w600),
    );
  }
}
