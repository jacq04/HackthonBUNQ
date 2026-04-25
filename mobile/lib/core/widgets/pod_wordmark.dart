import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/tokens.dart';

/// pod wordmark — lowercase, heavy Inter. An ambigram like bunq: "pod"
/// reads the same when you rotate it 180°. We don't animate the flip but
/// we keep the letters visually balanced so the symmetry is sensible.
class PodWordmark extends StatelessWidget {
  final double size;
  final Color? color;
  const PodWordmark({super.key, this.size = 72, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      'pod.',
      style: GoogleFonts.inter(
        fontSize: size,
        fontWeight: FontWeight.w900,
        letterSpacing: -size * 0.06,
        height: 0.9,
        color: color ?? KittyColors.coral,
      ),
    );
  }
}
