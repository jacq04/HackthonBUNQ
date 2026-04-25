import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../services/api.dart';

class FindCirclePage extends StatefulWidget {
  const FindCirclePage({super.key});

  @override
  State<FindCirclePage> createState() => _FindCirclePageState();
}

class _FindCirclePageState extends State<FindCirclePage> {
  final _goal = TextEditingController();
  final _amount = TextEditingController(text: '250');
  final _cycles = TextEditingController(text: '6');
  final _culture = TextEditingController();
  String _urgency = 'medium';
  bool _busy = false;
  MatchResult? _result;

  @override
  void dispose() {
    _goal.dispose();
    _amount.dispose();
    _cycles.dispose();
    _culture.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amt = (double.tryParse(_amount.text) ?? 0) * 100;
    final n = int.tryParse(_cycles.text) ?? 0;
    if (_goal.text.trim().isEmpty || amt < 500 || n < 2) {
      _toast('need a goal, amount ≥ €5, and ≥ 2 cycles');
      return;
    }
    setState(() => _busy = true);
    HapticFeedback.mediumImpact();
    try {
      final r = await KittyApi().findCircle(
        contributionAmountCents: amt.round(),
        cycleCount: n,
        goal: _goal.text.trim(),
        urgency: _urgency,
        culturalHint: _culture.text.trim().isEmpty ? null : _culture.text.trim(),
      );
      if (mounted) {
        HapticFeedback.heavyImpact();
        setState(() => _result = r);
      }
    } catch (e) {
      if (mounted) _toast('matchmaker failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('find a circle'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: KittyDurations.medium,
          switchInCurve: Curves.easeOutCubic,
          child: _result == null ? _form() : _resultCard(_result!),
        ),
      ),
    );
  }

  Widget _form() {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: const ValueKey('form'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('what are you saving for?',
              style: t.headlineMedium?.copyWith(color: KittyColors.bowl)),
          const SizedBox(height: 6),
          Text(
            'The Matchmaker joins you to an open circle — or forms one with compatible savers.',
            style: t.bodyMedium?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.65)),
          ),
          const SizedBox(height: 28),
          _Field(label: 'goal', child: TextField(
            controller: _goal,
            decoration: const InputDecoration(hintText: 'tuition deposit · wedding · emergency fund'),
            maxLines: 2,
            style: Theme.of(context).textTheme.bodyLarge,
          )),
          Row(children: [
            Expanded(child: _Field(label: 'per month (€)', child: TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: Theme.of(context).textTheme.titleLarge,
            ))),
            const SizedBox(width: 12),
            Expanded(child: _Field(label: 'over # months', child: TextField(
              controller: _cycles,
              keyboardType: TextInputType.number,
              style: Theme.of(context).textTheme.titleLarge,
            ))),
          ]),
          _Field(
            label: 'urgency',
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'low', label: Text('low')),
                ButtonSegment(value: 'medium', label: Text('medium')),
                ButtonSegment(value: 'high', label: Text('high')),
              ],
              selected: {_urgency},
              onSelectionChanged: (s) {
                HapticFeedback.selectionClick();
                setState(() => _urgency = s.first);
              },
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((s) =>
                    s.contains(WidgetState.selected) ? KittyColors.coral : Colors.transparent),
                foregroundColor: WidgetStateProperty.resolveWith((s) =>
                    s.contains(WidgetState.selected) ? KittyColors.cream : KittyColors.dusk),
                shape: WidgetStateProperty.all(RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
              ),
            ),
          ),
          _Field(label: 'tradition (optional)', child: TextField(
            controller: _culture,
            decoration: const InputDecoration(
              hintText: 'Susu · Chit fund · Tanda · Tontine · Kye · Hui',
            ),
            style: Theme.of(context).textTheme.bodyLarge,
          )),
          const SizedBox(height: 12),
          CoralButton(
            label: 'ask the matchmaker',
            hero: true,
            loading: _busy,
            onPressed: _busy ? null : _submit,
            leading: const Text('🧭', style: TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: 20),
          Text(
            'Kitty runs a Vetting agent on your bunq history, then the Matchmaker '
            'either joins you to an open circle, forms a new one, or waitlists you.',
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.5),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(MatchResult r) {
    final t = Theme.of(context).textTheme;
    final icon = switch (r.action) {
      'joined' => '🤝',
      'formed' => '✨',
      'waitlisted' => '⏳',
      _ => '🤔',
    };
    final headline = switch (r.action) {
      'joined' => "you're in",
      'formed' => "new circle formed",
      'waitlisted' => "on the waitlist",
      _ => "hmm",
    };
    return Padding(
      key: const ValueKey('result'),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text(icon,
                  style: const TextStyle(fontSize: 68),
                  textAlign: TextAlign.center)
              .animate()
              .scale(begin: const Offset(0.4, 0.4), curve: Curves.elasticOut, duration: 700.ms)
              .fadeIn(),
          const SizedBox(height: 18),
          Text(headline,
                  textAlign: TextAlign.center,
                  style: t.displaySmall?.copyWith(color: KittyColors.bowl))
              .animate()
              .fadeIn(delay: 180.ms)
              .slideY(begin: 0.2),
          if (r.groupName != null) ...[
            const SizedBox(height: 6),
            Text(r.groupName!,
                    textAlign: TextAlign.center, style: t.titleLarge?.copyWith(color: KittyColors.dusk))
                .animate()
                .fadeIn(delay: 280.ms),
          ],
          const SizedBox(height: 20),
          _TrustChip(score: r.trustScore).animate().fadeIn(delay: 360.ms).scale(begin: const Offset(0.9, 0.9)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: KittyColors.soft.withValues(alpha: 0.6),
              borderRadius: const BorderRadius.all(KittyRadius.l),
            ),
            child: Text(
              r.rationale,
              style: t.bodyMedium?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.78),
                height: 1.5,
              ),
            ),
          ).animate().fadeIn(delay: 460.ms).slideY(begin: 0.1),
          const Spacer(),
          CoralButton(
            label: r.groupId != null ? 'open circle' : 'done',
            hero: true,
            onPressed: () {
              if (r.groupId != null) {
                context.go('/group/${r.groupId}');
              } else {
                context.go('/');
              }
            },
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: t.labelSmall?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.55))),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _TrustChip extends StatelessWidget {
  final int score;
  const _TrustChip({required this.score});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = score >= 70
        ? KittyColors.moss
        : score >= 50
            ? KittyColors.amber
            : KittyColors.rust;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: const BorderRadius.all(KittyRadius.full),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined, size: 16, color: color),
            const SizedBox(width: 6),
            Text('trust score $score',
                style: t.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
