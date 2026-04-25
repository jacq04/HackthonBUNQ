import 'package:flutter/material.dart';

/// Design tokens — single source of truth for every color/spacing/radius
/// decision. Two palettes (light + dark) that keep the bowl-and-coral identity.
class KittyColors {
  const KittyColors._();

  // Brand core — modeled on the Marvilo/bunq UI kit (PDF page 4): pure black
  // canvas, charcoal cards, bunq orange as the brand accent + CTA, green as
  // a savings/success accent. The app is LOCKED to dark mode (main.dart).
  //
  // Token meanings have been flipped vs. the original light-canvas design so
  // existing call sites stay valid:
  //   - `dusk` was dark ink → now LIGHT ink (legible on the black canvas).
  //   - `bowl` was deep teal accent → now BUNQ ORANGE (the brand accent that
  //      most "color: bowl" headlines/borders should pop in).
  //   - `cream` stays LIGHT — it's still used for text-on-orange and as the
  //      contrasting fill for accent pills.
  //   - `soft` is now a muted dark surface for cards on the canvas.
  static const bowl = Color(0xFFFF7A1A);  // bunq orange brand accent
  static const cream = Color(0xFFF2F2F2); // near-white text/pill fill
  static const coral = Color(0xFFFF7A1A); // bunq orange — primary CTA
  static const dusk = Color(0xFFF4F4F4);  // primary text color on dark canvas
  static const soft = Color(0xFF1A1A1A);  // muted card surface on the canvas
  static const ember = Color(0xFFE66200); // orange-pressed
  static const moss = Color(0xFF1AC97F);  // bunq Together green — savings/success accent
  static const amber = Color(0xFFE6B23A); // warning
  static const rust = Color(0xFFE05A4D);  // danger
  // Explicit dark-ink token — used when we need maximum contrast on a bright
  // accent (e.g. dark text on the orange CTA pill). Keep pristine: the rest of
  // the palette is light, so this is the singular "very dark" token.
  static const ink = Color(0xFF0A0A0A);

  // Agent accent hues — round colored discs in the kit's icon row.
  static const agentConstitution = Color(0xFFD4A04A);
  static const agentCollector = Color(0xFF3F8AC4);
  static const agentMediator = Color(0xFFB13895); // pink/magenta disc
  static const agentEmergency = Color(0xFFE05A4D);
  static const agentCoach = Color(0xFF1AC97F);
  static const agentMatchmaker = Color(0xFFFF7A1A);
  static const agentVetting = Color(0xFF1B6E78); // teal disc
  static const agentAuditor = Color(0xFF0E2747); // navy disc

  // Dark theme variants — used by theme.dart to drive the canvas + ink + cards.
  // The kit's hero canvas is pure black; the cards are a hair lighter so the
  // edge reads. We keep the orange as the secondary `bowlDark` accent so any
  // theme-driven secondary tinting picks up the brand color.
  static const bowlDark = Color(0xFFFF7A1A);   // orange accent in dark mode
  static const creamDark = Color(0xFF0A0A0A);  // pure black canvas (with a whisper of warmth)
  static const duskDark = Color(0xFFF4F4F4);   // near-white ink
  static const softDark = Color(0xFF1A1A1A);   // muted card on the canvas
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
  // bunq's surfaces lean even rounder than our previous values — bigger pills
  // on buttons, softer card corners.
  static const Radius s = Radius.circular(14);
  static const Radius m = Radius.circular(22);
  static const Radius l = Radius.circular(30);
  static const Radius xl = Radius.circular(40);
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
