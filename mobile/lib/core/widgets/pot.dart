import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// The signature Kitty widget: a round ceramic bowl that fills with bunq-
/// green "liquid" as contributions post. Uses a CustomPainter with a cosine-
/// wave
/// surface + specular highlight + drop-shadow so it reads as physical, not
/// flat. Animates fill ratio with a spring curve (elastic settle).
class Pot extends StatefulWidget {
  final double filled;      // 0..1
  final double size;
  final bool glisten;       // true = animated surface ripple
  const Pot({
    super.key,
    required this.filled,
    this.size = 240,
    this.glisten = true,
  });

  @override
  State<Pot> createState() => _PotState();
}

class _PotState extends State<Pot> with TickerProviderStateMixin {
  late final AnimationController _fill;
  late final AnimationController _ripple;
  late Animation<double> _fillAnim;

  @override
  void initState() {
    super.initState();
    _fill = AnimationController(
      vsync: this,
      duration: KittyDurations.pot,
    );
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _fillAnim = CurvedAnimation(parent: _fill, curve: Curves.easeOutCubic);
    _fill.animateTo(widget.filled.clamp(0, 1));
  }

  @override
  void didUpdateWidget(covariant Pot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filled != widget.filled) {
      _fill.animateTo(
        widget.filled.clamp(0, 1),
        curve: Curves.elasticOut,
        duration: const Duration(milliseconds: 1400),
      );
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_fillAnim, _ripple]),
        builder: (_, __) {
          return CustomPaint(
            painter: _PotPainter(
              fill: _fillAnim.value,
              ripplePhase: widget.glisten ? _ripple.value * 2 * math.pi : 0,
            ),
          );
        },
      ),
    );
  }
}

class _PotPainter extends CustomPainter {
  final double fill;           // 0..1
  final double ripplePhase;    // radians
  _PotPainter({required this.fill, required this.ripplePhase});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.52);
    final radius = size.width * 0.42;

    // ── Drop shadow under the bowl ──────────────────────────────────────────
    final shadowPaint = Paint()
      ..color = const Color(0x29000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(0, radius * 0.35),
        width: radius * 1.7,
        height: radius * 0.5,
      ),
      shadowPaint,
    );

    // ── Bowl body (the ceramic) ─────────────────────────────────────────────
    // Cool off-white ceramic with a subtle teal-tint shadow at the base, so
    // the bowl reads as china against the bunq-green liquid.
    final bowlGrad = Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0xFFF6F8F4),
          const Color(0xFFE2E9DF),
          const Color(0xFFB7C4B8),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, 0.55, 1],
      ).createShader(
        Rect.fromCircle(center: center, radius: radius),
      );
    canvas.drawCircle(center, radius, bowlGrad);

    // ── Liquid (coral) — clipped to the bowl ────────────────────────────────
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius - 3)));

    final liquidTop = center.dy + radius - (fill * radius * 1.95);

    // surface wave
    final wavePath = Path();
    wavePath.moveTo(center.dx - radius, center.dy + radius);
    for (double x = -radius; x <= radius; x += 2) {
      final phase = ripplePhase + x * 0.08;
      final surfaceY =
          liquidTop + math.sin(phase) * 2.4 + math.sin(phase * 2.3) * 1.1;
      wavePath.lineTo(center.dx + x, surfaceY);
    }
    wavePath.lineTo(center.dx + radius, center.dy + radius);
    wavePath.close();

    final liquidGrad = Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0xFF1AC97F), // bunq Together green — surface
          const Color(0xFF0B8056), // deeper teal at the floor
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(
        Rect.fromLTRB(
          center.dx - radius,
          liquidTop,
          center.dx + radius,
          center.dy + radius,
        ),
      );
    canvas.drawPath(wavePath, liquidGrad);

    // Specular meniscus highlight
    final meniscus = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5);
    final meniscusPath = Path();
    for (double x = -radius * 0.85; x <= radius * 0.85; x += 2) {
      final phase = ripplePhase + x * 0.08;
      final surfaceY =
          liquidTop + math.sin(phase) * 2.4 + math.sin(phase * 2.3) * 1.1;
      if (x == -radius * 0.85) {
        meniscusPath.moveTo(center.dx + x, surfaceY);
      } else {
        meniscusPath.lineTo(center.dx + x, surfaceY);
      }
    }
    canvas.drawPath(meniscusPath, meniscus);

    canvas.restore();

    // ── Rim highlight ───────────────────────────────────────────────────────
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.55),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, rim);

    // ── Inner shadow near rim ───────────────────────────────────────────────
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = const Color(0x22000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(center, radius - 2, inner);
  }

  @override
  bool shouldRepaint(covariant _PotPainter old) =>
      old.fill != fill || old.ripplePhase != ripplePhase;
}
