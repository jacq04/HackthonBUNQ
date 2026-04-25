import 'package:flutter/material.dart';

import '../../features/voice/voice_sheet.dart';
import '../theme/tokens.dart';

/// Floating "talk to pod." pill — opens the live voice tour modal.
/// Drop into a Stack at the bottom-right of any page.
class TalkToPodButton extends StatelessWidget {
  const TalkToPodButton({super.key, this.bottomInset = 24});

  /// Distance from the bottom of the parent Stack. Pages with their own
  /// safe-area padding can keep the default; pages with a bottom bar
  /// should pass a bigger value.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 18,
      bottom: bottomInset,
      child: _Pulse(
        child: Material(
          color: KittyColors.coral,
          shape: const StadiumBorder(),
          elevation: 6,
          shadowColor: KittyColors.coral.withValues(alpha: 0.5),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => VoiceSheet.show(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mic, color: KittyColors.cream, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'talk to pod.',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: KittyColors.cream,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});
  final Widget child;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        // expanding ring 0..1
        final scale = 1.0 + t * 0.45;
        final opacity = (1.0 - t).clamp(0.0, 1.0) * 0.5;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // ring
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Transform.scale(
                    scale: scale,
                    child: Opacity(
                      opacity: opacity,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.rectangle,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: KittyColors.coral,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}
