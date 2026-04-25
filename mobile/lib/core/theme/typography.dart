import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Typography scale — bunq is sans-only with very heavy display weights and
/// tight negative tracking on numerics. We lean fully into Inter (no serif)
/// so amounts and headlines feel like the bunq app's account-card slabs.
class KittyType {
  const KittyType._();

  static TextTheme build({required Color ink}) {
    final display = GoogleFonts.inter(
      color: ink,
      fontWeight: FontWeight.w800,
      height: 0.95,
      letterSpacing: -2.4,
    );

    final headline = GoogleFonts.inter(
      color: ink,
      fontWeight: FontWeight.w700,
      height: 1.08,
      letterSpacing: -0.8,
    );

    final sans = GoogleFonts.inter(color: ink);

    return TextTheme(
      displayLarge: display.copyWith(fontSize: 76),
      displayMedium: display.copyWith(fontSize: 60),
      displaySmall: display.copyWith(fontSize: 44),

      headlineLarge: headline.copyWith(fontSize: 36),
      headlineMedium: headline.copyWith(fontSize: 28),
      headlineSmall: headline.copyWith(fontSize: 22),

      titleLarge: sans.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.25, letterSpacing: -0.2),
      titleMedium: sans.copyWith(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.1),
      titleSmall: sans.copyWith(fontSize: 15, fontWeight: FontWeight.w700),

      bodyLarge: sans.copyWith(fontSize: 17, fontWeight: FontWeight.w500, height: 1.45),
      bodyMedium: sans.copyWith(fontSize: 15, fontWeight: FontWeight.w500, height: 1.45),
      bodySmall: sans.copyWith(fontSize: 13, fontWeight: FontWeight.w500, height: 1.4),

      labelLarge: sans.copyWith(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.1),
      labelMedium: sans.copyWith(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6),
      labelSmall: sans.copyWith(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4),
    );
  }
}
