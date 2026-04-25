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
  PodCardPalette('forest', Color(0xFF0B4032), Color(0xFF0E6E4B)),   // signature bunq green
  PodCardPalette('ember', Color(0xFFE9663C), Color(0xFFB33E1F)),     // coral → rust
  PodCardPalette('plum', Color(0xFF2B1B44), Color(0xFF613A8C)),      // deep plum → violet
  PodCardPalette('sand', Color(0xFFE7D3A1), Color(0xFFB58A55)),      // cream → caramel
  PodCardPalette('tide', Color(0xFF0E3B4D), Color(0xFF1B89A1)),      // navy → teal
  PodCardPalette('blush', Color(0xFFF1AF9E), Color(0xFFD57A7A)),     // soft peach → rose
];

PodCardPalette paletteFor(int index) =>
    kPodCardPalettes[index.abs() % kPodCardPalettes.length];
