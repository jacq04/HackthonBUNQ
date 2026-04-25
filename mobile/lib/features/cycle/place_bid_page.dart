import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../services/api.dart';

/// Place / replace a bid for the current cycle. Urgency chips + reason
/// textarea. The Bidding agent reads both and scores the bid when resolving.
class PlaceBidPage extends StatefulWidget {
  final String groupId;
  final int cycleMonth;
  final int potCents;
  const PlaceBidPage({
    super.key,
    required this.groupId,
    required this.cycleMonth,
    required this.potCents,
  });

  @override
  State<PlaceBidPage> createState() => _PlaceBidPageState();
}

class _PlaceBidPageState extends State<PlaceBidPage> {
  final _reason = TextEditingController();
  String _urgency = 'medium';
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_reason.text.trim().length < 10) {
      _toast('reason must be at least 10 characters');
      return;
    }
    setState(() => _busy = true);
    HapticFeedback.heavyImpact();
    try {
      await KittyApi().placeBid(
        widget.groupId,
        widget.cycleMonth,
        urgency: _urgency,
        reason: _reason.text.trim(),
      );
      if (!mounted) return;
      _toast('bid placed');
      context.pop();
    } catch (e) {
      if (mounted) _toast('could not bid: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final potEur = widget.potCents / 100;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          children: [
            Text('bid for the pot',
                    style: t.headlineMedium?.copyWith(color: KittyColors.bowl))
                .animate()
                .fadeIn()
                .slideY(begin: 0.1),
            const SizedBox(height: 4),
            Text(
              'cycle ${widget.cycleMonth}  ·  €${potEur.toStringAsFixed(0)} at stake',
              style: t.bodyMedium?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.65),
              ),
            ).animate().fadeIn(delay: 80.ms),
            const SizedBox(height: 28),

            Text('URGENCY',
                style: t.labelSmall
                    ?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.55))),
            const SizedBox(height: 10),
            _UrgencyChips(
              value: _urgency,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _urgency = v);
              },
            ).animate().fadeIn(delay: 160.ms).slideY(begin: 0.08),

            const SizedBox(height: 24),

            Text('REASON',
                style: t.labelSmall
                    ?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.55))),
            const SizedBox(height: 10),
            TextField(
              controller: _reason,
              minLines: 4,
              maxLines: 8,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText:
                    "The reason you need it this month — the Bidding agent reads this.",
              ),
              style: t.bodyLarge,
            ).animate().fadeIn(delay: 220.ms).slideY(begin: 0.08),

            const SizedBox(height: 18),

            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: KittyColors.soft.withValues(alpha: 0.5),
                borderRadius: const BorderRadius.all(KittyRadius.m),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      size: 18, color: KittyColors.dusk),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "The Bidding agent scores bids on urgency + the plausibility "
                      "of your reason. Repeat 'critical' claims without cause are "
                      "weighted lower.",
                      style: t.bodySmall?.copyWith(
                        color: KittyColors.dusk.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: 280.ms),

            const SizedBox(height: 28),

            CoralButton(
              label: 'place bid',
              hero: true,
              loading: _busy,
              onPressed: _busy ? null : _submit,
              leading: const Text('🎯', style: TextStyle(fontSize: 16)),
            ).animate().fadeIn(delay: 360.ms).slideY(begin: 0.08),
          ],
        ),
      ),
    );
  }
}

class _UrgencyChips extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _UrgencyChips({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const levels = ['low', 'medium', 'high', 'critical'];
    const colors = {
      'low': KittyColors.soft,
      'medium': KittyColors.amber,
      'high': KittyColors.coral,
      'critical': KittyColors.rust,
    };
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: levels.map((lvl) {
        final selected = value == lvl;
        final fg = selected ? KittyColors.cream : KittyColors.dusk;
        final bg = selected
            ? colors[lvl]!
            : KittyColors.cream;
        return GestureDetector(
          onTap: () => onChanged(lvl),
          child: AnimatedContainer(
            duration: KittyDurations.short,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: const BorderRadius.all(KittyRadius.full),
              border: Border.all(
                color: selected
                    ? colors[lvl]!
                    : KittyColors.dusk.withValues(alpha: 0.15),
                width: 1.5,
              ),
              boxShadow: selected ? KittyShadows.card : null,
            ),
            child: Text(
              lvl,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
