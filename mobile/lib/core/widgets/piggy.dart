import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// Piggy bank that fills with coral "savings liquid" as contributions post.
/// Mirrors the Pot widget's API: pass `filled` ∈ 0..1 — the body fills from
/// the trotters up. Coin slot on the back, dot eye, perky ear, curl tail.
/// The fill animates with a spring on every update, so a new contribution
/// gives a satisfying liquid-rises beat.
class Piggy extends StatefulWidget {
  final double filled;     // 0..1
  final double size;
  final bool glisten;      // animated surface ripple
  const Piggy({
    super.key,
    required this.filled,
    this.size = 240,
    this.glisten = true,
  });

  @override
  State<Piggy> createState() => _PiggyState();
}

class _PiggyState extends State<Piggy> with TickerProviderStateMixin {
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
  void didUpdateWidget(covariant Piggy oldWidget) {
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
            painter: _PiggyPainter(
              fill: _fillAnim.value,
              ripplePhase: widget.glisten ? _ripple.value * 2 * math.pi : 0,
            ),
          );
        },
      ),
    );
  }
}

class _PiggyPainter extends CustomPainter {
  final double fill;          // 0..1
  final double ripplePhase;   // radians
  _PiggyPainter({required this.fill, required this.ripplePhase});

  // ── pink piggy palette ────────────────────────────────────────────────────
  static const _bodyTop = Color(0xFFF7B7B0);
  static const _bodyMid = Color(0xFFEC8E84);
  static const _bodyDeep = Color(0xFFC85A4F);
  static const _liquidTop = Color(0xFFE9663C);
  static const _liquidBottom = Color(0xFFD84823);
  static const _coinSlot = Color(0xFF3A2A2A);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Body geometry — a big rounded rectangle in the lower middle of the frame.
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(w * 0.50, h * 0.56),
        width: w * 0.78,
        height: h * 0.50,
      ),
      Radius.circular(w * 0.26),
    );
    final snout = Rect.fromCenter(
      center: Offset(w * 0.86, h * 0.58),
      width: w * 0.18,
      height: h * 0.18,
    );

    // ── drop shadow ──────────────────────────────────────────────────────────
    final shadowPaint = Paint()
      ..color = const Color(0x33000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.5, h * 0.86),
        width: w * 0.66,
        height: h * 0.06,
      ),
      shadowPaint,
    );

    // ── back legs (drawn behind body) ────────────────────────────────────────
    _leg(canvas, Offset(w * 0.30, h * 0.78), w * 0.10, h * 0.14);
    _leg(canvas, Offset(w * 0.66, h * 0.78), w * 0.10, h * 0.14);

    // ── body ─────────────────────────────────────────────────────────────────
    final bodyPaint = Paint()
      ..shader = LinearGradient(
        colors: [_bodyTop, _bodyMid, _bodyDeep],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, 0.55, 1],
      ).createShader(body.outerRect);
    canvas.drawRRect(body, bodyPaint);

    // ── snout (oval, slightly darker) ────────────────────────────────────────
    final snoutPaint = Paint()
      ..shader = LinearGradient(
        colors: [_bodyMid, _bodyDeep],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(snout);
    canvas.drawOval(snout, snoutPaint);
    // nostrils
    final nostril = Paint()..color = const Color(0xFF6B2A24);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.83, h * 0.585),
        width: w * 0.018,
        height: h * 0.028,
      ),
      nostril,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.89, h * 0.585),
        width: w * 0.018,
        height: h * 0.028,
      ),
      nostril,
    );

    // ── ear ──────────────────────────────────────────────────────────────────
    final earPath = Path()
      ..moveTo(w * 0.66, h * 0.34)
      ..quadraticBezierTo(w * 0.74, h * 0.18, w * 0.82, h * 0.34)
      ..close();
    canvas.drawPath(
      earPath,
      Paint()
        ..shader = LinearGradient(
          colors: [_bodyMid, _bodyDeep],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(earPath.getBounds()),
    );

    // ── eye ──────────────────────────────────────────────────────────────────
    final eye = Paint()..color = const Color(0xFF2B1A18);
    canvas.drawCircle(Offset(w * 0.74, h * 0.50), w * 0.018, eye);
    canvas.drawCircle(
      Offset(w * 0.745, h * 0.495),
      w * 0.006,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );

    // ── tail (curl) ──────────────────────────────────────────────────────────
    final tail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.018
      ..strokeCap = StrokeCap.round
      ..color = _bodyDeep;
    final tailPath = Path()
      ..moveTo(w * 0.115, h * 0.50)
      ..quadraticBezierTo(w * 0.06, h * 0.42, w * 0.085, h * 0.36)
      ..quadraticBezierTo(w * 0.135, h * 0.30, w * 0.10, h * 0.27);
    canvas.drawPath(tailPath, tail);

    // ── coral liquid — clipped to body ───────────────────────────────────────
    canvas.save();
    canvas.clipRRect(body);

    final liquidTop = body.bottom - (fill * body.height * 0.95);
    final wavePath = Path();
    wavePath.moveTo(body.left, body.bottom);
    for (double x = body.left; x <= body.right; x += 2) {
      final phase = ripplePhase + (x - body.left) * 0.08;
      final surfaceY =
          liquidTop + math.sin(phase) * 2.4 + math.sin(phase * 2.3) * 1.1;
      wavePath.lineTo(x, surfaceY);
    }
    wavePath.lineTo(body.right, body.bottom);
    wavePath.close();

    final liquidGrad = Paint()
      ..shader = const LinearGradient(
        colors: [_liquidTop, _liquidBottom],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTRB(
        body.left,
        liquidTop,
        body.right,
        body.bottom,
      ));
    canvas.drawPath(wavePath, liquidGrad);

    // meniscus highlight
    final meniscus = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5);
    final meniscusPath = Path();
    for (double x = body.left + 6; x <= body.right - 6; x += 2) {
      final phase = ripplePhase + (x - body.left) * 0.08;
      final surfaceY =
          liquidTop + math.sin(phase) * 2.4 + math.sin(phase * 2.3) * 1.1;
      if (x == body.left + 6) {
        meniscusPath.moveTo(x, surfaceY);
      } else {
        meniscusPath.lineTo(x, surfaceY);
      }
    }
    canvas.drawPath(meniscusPath, meniscus);

    canvas.restore();

    // ── coin slot (on top of fill so it stays visible) ───────────────────────
    final slotRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(w * 0.45, h * 0.36),
        width: w * 0.20,
        height: h * 0.022,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(slotRect, Paint()..color = _coinSlot);
    // glint inside slot
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(w * 0.43, h * 0.354),
          width: w * 0.06,
          height: h * 0.006,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );

    // ── body specular highlight ──────────────────────────────────────────────
    final hi = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.34, h * 0.46),
        width: w * 0.16,
        height: h * 0.06,
      ),
      hi,
    );
  }

  void _leg(Canvas canvas, Offset center, double width, double height) {
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: width, height: height),
      Radius.circular(width * 0.35),
    );
    canvas.drawRRect(
      r,
      Paint()
        ..shader = LinearGradient(
          colors: [_bodyMid, _bodyDeep],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(r.outerRect),
    );
  }

  @override
  bool shouldRepaint(covariant _PiggyPainter old) =>
      old.fill != fill || old.ripplePhase != ripplePhase;
}
