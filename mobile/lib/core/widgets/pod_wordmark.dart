import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// pod. wordmark — renders the official rainbow-card SVG logo from
/// `assets/logo_small.svg`. The `size` parameter is the rendered HEIGHT
/// (the original font-size knob translated to image height) so existing
/// call sites keep working: a 52-tall logo on the wallet, 96 on sign-in,
/// 32 on the admin control room.
///
/// `color` is accepted but ignored — the logo is intentionally polychrome.
class PodWordmark extends StatelessWidget {
  final double size;
  final Color? color;
  const PodWordmark({super.key, this.size = 72, this.color});

  @override
  Widget build(BuildContext context) {
    // Aspect ratio of logo_small.svg ≈ 3:2 (240×160 in the source viewBox).
    // Scaling by height keeps it consistent with the previous text-wordmark
    // sizing API while letting the width breathe.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: size * 0.32,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.18),
        child: SvgPicture.asset(
          'assets/logo_small.svg',
          height: size,
          fit: BoxFit.contain,
          semanticsLabel: 'pod. — chit together, powered by bunq',
        ),
      ),
    );
  }
}
