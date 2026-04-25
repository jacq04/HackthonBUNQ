import 'package:flutter/material.dart';

/// Gradient palettes for account cards — lifted from the bunq app's feel:
/// vivid duotones that read as physical-card surfaces.
class PodCardPalette {
  final String name;
  final Color from;
  final Color to;
  const PodCardPalette(this.name, this.from, this.to);

  List<Color> get gradient => [from, to];
}

const kPodCardPalettes = <PodCardPalette>[
  // Signature bunq Together-green duotone — leads the carousel.
  PodCardPalette('forest', Color(0xFF053A2D), Color(0xFF1AC97F)),
  // Midnight navy → mint, the second hero card surface.
  PodCardPalette('midnight', Color(0xFF06141C), Color(0xFF13D0AA)),
  // Deep plum → violet, kept for variety.
  PodCardPalette('plum', Color(0xFF2B1B44), Color(0xFF8B5BC9)),
  // Charcoal → mint — premium "black card" feel, bunq-styled.
  PodCardPalette('onyx', Color(0xFF0E1410), Color(0xFF2BA37A)),
  // Tide: navy → teal, complementary to the brand green.
  PodCardPalette('tide', Color(0xFF0E3B4D), Color(0xFF1B89A1)),
  // Aubergine → magenta, bunq-style accent card kept in the rotation.
  PodCardPalette('aubergine', Color(0xFF2A0E2A), Color(0xFFB13895)),
];

PodCardPalette paletteFor(int index) =>
    kPodCardPalettes[index.abs() % kPodCardPalettes.length];
