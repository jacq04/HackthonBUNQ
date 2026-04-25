import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tokens.dart';

/// Primary button. Scale-springs on press, fires a medium-impact haptic, and
/// renders a glowing fill for the hero CTA variant.
class CoralButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final Widget? leading;
  final bool hero;           // bigger, lifted shadow, subtle inner glow
  final bool loading;
  final Color? color;
  final Color? foreground;

  const CoralButton({
    super.key,
    required this.label,
    this.onPressed,
    this.leading,
    this.hero = false,
    this.loading = false,
    this.color,
    this.foreground,
  });

  @override
  State<CoralButton> createState() => _CoralButtonState();
}

class _CoralButtonState extends State<CoralButton> {
  bool _down = false;

  void _press(bool v) {
    if (v && widget.onPressed != null) {
      HapticFeedback.mediumImpact();
    }
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null || widget.loading;
    final bg = widget.color ?? KittyColors.coral;
    final fg = widget.foreground ?? KittyColors.cream;

    return GestureDetector(
      onTapDown: (_) => _press(true),
      onTapUp: (_) {
        _press(false);
        if (!widget.loading) widget.onPressed?.call();
      },
      onTapCancel: () => _press(false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        duration: KittyDurations.micro,
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: KittyDurations.short,
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: widget.hero ? 28 : 24,
            vertical: widget.hero ? 20 : 16,
          ),
          decoration: BoxDecoration(
            color: disabled ? bg.withValues(alpha: 0.35) : bg,
            borderRadius: const BorderRadius.all(KittyRadius.l),
            boxShadow: disabled
                ? []
                : widget.hero
                    ? [
                        BoxShadow(
                          color: bg.withValues(alpha: 0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: bg.withValues(alpha: 0.18),
                          blurRadius: 60,
                          offset: const Offset(0, 24),
                        ),
                      ]
                    : KittyShadows.card,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.loading)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(fg),
                  ),
                )
              else ...[
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: 10),
                ],
                Text(
                  widget.label,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
