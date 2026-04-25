import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Kitty typography scale — Fraunces (display serif, distinctive "k" and "y")
/// paired with Inter (body sans for hierarchy clarity). Heavy-optical-size
/// tuning gives the hero Kitty wordmark its warmth.
class KittyType {
  const KittyType._();

  static TextTheme build({required Color ink}) {
    // google_fonts doesn't expose FontVariation (variable-font axes) — use
    // concrete weights + optical sizing via weight/height tuning instead.
    final display = GoogleFonts.fraunces(
      color: ink,
      fontWeight: FontWeight.w600,
      height: 0.95,
      letterSpacing: -1.5,
    );

    final serif = GoogleFonts.fraunces(
      color: ink,
      fontWeight: FontWeight.w600,
      height: 1.08,
      letterSpacing: -0.3,
    );

    final sans = GoogleFonts.inter(color: ink);

    return TextTheme(
      displayLarge: display.copyWith(fontSize: 72),
      displayMedium: display.copyWith(fontSize: 56),
      displaySmall: display.copyWith(fontSize: 40),

      headlineLarge: serif.copyWith(fontSize: 36),
      headlineMedium: serif.copyWith(fontSize: 28),
      headlineSmall: serif.copyWith(fontSize: 22),

      titleLarge: sans.copyWith(fontSize: 20, fontWeight: FontWeight.w600, height: 1.25),
      titleMedium: sans.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
      titleSmall: sans.copyWith(fontSize: 15, fontWeight: FontWeight.w600),

      bodyLarge: sans.copyWith(fontSize: 17, fontWeight: FontWeight.w400, height: 1.45),
      bodyMedium: sans.copyWith(fontSize: 15, fontWeight: FontWeight.w400, height: 1.45),
      bodySmall: sans.copyWith(fontSize: 13, fontWeight: FontWeight.w400, height: 1.4),

      labelLarge: sans.copyWith(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.2),
      labelMedium: sans.copyWith(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6),
      labelSmall: sans.copyWith(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.1),
    );
  }
}
