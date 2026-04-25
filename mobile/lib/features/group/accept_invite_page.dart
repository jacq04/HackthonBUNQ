import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../services/api.dart';

/// Invitation acceptance: charter summary + SEPA-style auto-debit mandate + T&Cs.
/// On accept: backend creates a bunq autoflow + mandates row, member flips to
/// 'accepted'. Once all N accept, group auto-transitions to 'chartered'.
class AcceptInvitePage extends StatefulWidget {
  final String groupId;
  const AcceptInvitePage({super.key, required this.groupId});

  @override
  State<AcceptInvitePage> createState() => _AcceptInvitePageState();
}

class _AcceptInvitePageState extends State<AcceptInvitePage> {
  Map<String, dynamic>? _group;
  Map<String, dynamic>? _charter;
  int _debitDay = 1;
  bool _agreed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await KittyApi().getGroup(widget.groupId);
      if (!mounted) return;
      setState(() {
        _group = r['group'] as Map<String, dynamic>;
        _charter = r['charter'] as Map<String, dynamic>?;
      });
    } catch (_) {/* noop */}
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    HapticFeedback.heavyImpact();
    try {
      final r = await KittyApi().respondToInvite(
        widget.groupId,
        decision: 'accept',
        debitDay: _debitDay,
      );
      if (!mounted) return;
      final tail = switch (r.groupStatus) {
        'active' => 'pod started — first debit posted',
        'chartered' => 'pod chartered!',
        _ => 'waiting on others',
      };
      _showToast('${r.acceptedCount}/${r.targetCount} accepted — $tail');
      context.pop(true);
    } catch (e) {
      if (mounted) _showToast('could not accept: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    setState(() => _busy = true);
    try {
      await KittyApi().respondToInvite(widget.groupId, decision: 'decline');
      if (!mounted) return;
      _showToast('declined');
      context.pop();
    } catch (e) {
      if (mounted) _showToast('could not decline: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showToast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final g = _group;
    final c = _charter?['content'] as Map<String, dynamic>?;
    final amount = (g?['contribution_amount_cents'] ?? 0) / 100;
    final cycles = g?['cycle_count'] ?? 0;
    final graceDays = c?['grace_period_days'] ?? g?['grace_period_days'] ?? 3;
    final penaltyBps = c?['penalty_bps'] ?? g?['penalty_bps'] ?? 200;
    final monthlyCap = amount * 1.1;

    return Scaffold(
      body: SafeArea(
        child: g == null
            ? const Center(child: CircularProgressIndicator(color: KittyColors.coral))
            : ListView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => context.pop(),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "you've been invited",
                    style: t.labelMedium?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.55),
                    ),
                  ).animate().fadeIn(),
                  const SizedBox(height: 6),
                  Text(g['name'] as String,
                      style: t.displaySmall?.copyWith(color: KittyColors.bowl))
                      .animate()
                      .fadeIn(delay: 80.ms)
                      .slideY(begin: 0.1),
                  const SizedBox(height: 28),

                  // Charter summary
                  _SectionCard(
                    title: 'the charter',
                    rows: [
                      _KeyValue('contribution', '€${amount.toStringAsFixed(0)} / month'),
                      _KeyValue('cycles', '$cycles months'),
                      _KeyValue('grace period', '$graceDays days'),
                      _KeyValue('late penalty', '${(penaltyBps / 100).toStringAsFixed(1)}%'),
                    ],
                  ).animate().fadeIn(delay: 180.ms).slideY(begin: 0.08),

                  const SizedBox(height: 16),

                  // Auto-debit mandate
                  _SectionCard(
                    title: 'auto-debit mandate',
                    rows: [
                      _KeyValue('monthly cap', '€${monthlyCap.toStringAsFixed(0)}'),
                      _KeyValue('payout to', 'your bunq account'),
                    ],
                    children: [
                      const SizedBox(height: 16),
                      Text(
                        "debit day of the month",
                        style: t.labelMedium?.copyWith(
                          color: KittyColors.dusk.withValues(alpha: 0.65),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _DebitDayPicker(
                        value: _debitDay,
                        onChanged: (v) {
                          HapticFeedback.selectionClick();
                          setState(() => _debitDay = v);
                        },
                      ),
                    ],
                  ).animate().fadeIn(delay: 280.ms).slideY(begin: 0.08),

                  const SizedBox(height: 18),

                  // Consent
                  InkWell(
                    onTap: () => setState(() => _agreed = !_agreed),
                    borderRadius: const BorderRadius.all(KittyRadius.m),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Checkbox(checked: _agreed),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'I agree to the charter rules and authorize Kitty to '
                              'auto-debit €${amount.toStringAsFixed(0)} from my bunq '
                              'account on day $_debitDay each month for $cycles months.',
                              style: t.bodyMedium?.copyWith(
                                color: KittyColors.dusk.withValues(alpha: 0.85),
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(delay: 380.ms),

                  const SizedBox(height: 24),

                  CoralButton(
                    label: 'accept & authorize',
                    hero: true,
                    loading: _busy,
                    onPressed: _busy || !_agreed ? null : _accept,
                  ).animate().fadeIn(delay: 480.ms).slideY(begin: 0.08),

                  const SizedBox(height: 10),

                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : _decline,
                      child: Text(
                        'decline invitation',
                        style: t.labelMedium?.copyWith(
                          color: KittyColors.dusk.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _KeyValue {
  final String k;
  final String v;
  const _KeyValue(this.k, this.v);
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<_KeyValue> rows;
  final List<Widget> children;
  const _SectionCard({
    required this.title,
    required this.rows,
    this.children = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.all(KittyRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 12),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(r.k,
                        style: t.bodyMedium?.copyWith(
                          color: KittyColors.dusk.withValues(alpha: 0.6),
                        )),
                    Text(r.v,
                        style: t.titleMedium?.copyWith(
                          color: KittyColors.bowl,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                  ],
                ),
              )),
          ...children,
        ],
      ),
    );
  }
}

class _DebitDayPicker extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _DebitDayPicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(28, (i) {
          final day = i + 1;
          final selected = day == value;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => onChanged(day),
              child: AnimatedContainer(
                duration: KittyDurations.short,
                curve: Curves.easeOut,
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? KittyColors.coral : KittyColors.cream,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: selected ? KittyShadows.card : null,
                ),
                child: Text(
                  '$day',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color:
                            selected ? KittyColors.cream : KittyColors.bowl,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  final bool checked;
  const _Checkbox({required this.checked});
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: KittyDurations.short,
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: checked ? KittyColors.coral : Colors.transparent,
        border: Border.all(
          color: checked
              ? KittyColors.coral
              : KittyColors.dusk.withValues(alpha: 0.35),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: checked
          ? const Icon(Icons.check_rounded, color: KittyColors.cream, size: 18)
          : null,
    );
  }
}
