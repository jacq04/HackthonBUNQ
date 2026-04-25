import 'package:flutter/material.dart';

/// Design tokens — single source of truth for every color/spacing/radius
/// decision. Two palettes (light + dark) that keep the bowl-and-coral identity.
class KittyColors {
  const KittyColors._();

  // Brand core
  static const bowl = Color(0xFF3E4C29); // deep olive
  static const cream = Color(0xFFF5EEDC); // page bg (light)
  static const coral = Color(0xFFE9663C); // primary CTA
  static const dusk = Color(0xFF2B2D29); // text (light)
  static const soft = Color(0xFFDBD4C0); // muted surface
  static const ember = Color(0xFFB33E1F); // coral-pressed
  static const moss = Color(0xFF6A9F55); // success
  static const amber = Color(0xFFD8A23B); // warning
  static const rust = Color(0xFFC0443B); // danger

  // Agent accent hues (stay identifiable across themes)
  static const agentConstitution = Color(0xFFD4A04A);
  static const agentCollector = Color(0xFF5580C4);
  static const agentMediator = Color(0xFF8159B2);
  static const agentEmergency = Color(0xFFC0443B);
  static const agentCoach = Color(0xFF6A9F55);
  static const agentMatchmaker = Color(0xFFE9663C);
  static const agentVetting = Color(0xFF3E4C29);
  static const agentAuditor = Color(0xFF2B2D29);

  // Dark-mode equivalents
  static const bowlDark = Color(0xFFCDE0A6);
  static const creamDark = Color(0xFF14140F);
  static const duskDark = Color(0xFFF1EFE4);
  static const softDark = Color(0xFF2D2A22);
}

class KittySpacing {
  const KittySpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

class KittyRadius {
  const KittyRadius._();
  static const Radius s = Radius.circular(12);
  static const Radius m = Radius.circular(20);
  static const Radius l = Radius.circular(28);
  static const Radius xl = Radius.circular(36);
  static const Radius full = Radius.circular(999);
}

class KittyDurations {
  const KittyDurations._();
  // Motion should feel like breath — spring-forward, not linear.
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration short = Duration(milliseconds: 260);
  static const Duration medium = Duration(milliseconds: 420);
  static const Duration long = Duration(milliseconds: 680);
  static const Duration pot = Duration(milliseconds: 920);
}

class KittyShadows {
  const KittyShadows._();
  // Soft, warm, low-contrast — iOS-native defaults are too clinical for Kitty.
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x14000000),
      offset: Offset(0, 2),
      blurRadius: 8,
    ),
    BoxShadow(
      color: Color(0x0A000000),
      offset: Offset(0, 12),
      blurRadius: 30,
    ),
  ];
  static const List<BoxShadow> lift = [
    BoxShadow(
      color: Color(0x1F000000),
      offset: Offset(0, 4),
      blurRadius: 18,
    ),
    BoxShadow(
      color: Color(0x0F000000),
      offset: Offset(0, 16),
      blurRadius: 44,
    ),
  ];
  static const List<BoxShadow> pressed = [
    BoxShadow(
      color: Color(0x22000000),
      offset: Offset(0, 1),
      blurRadius: 3,
    ),
  ];
}
