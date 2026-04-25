import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/tokens.dart';
import '../../services/api.dart';
import 'create_circle_sheet.dart';

/// Admin's deep-dive into a single pod: facts, every participant by name with
/// the money they've moved, all cycles, recent ledger tape.
class AdminPodDetailPage extends StatefulWidget {
  final String groupId;
  const AdminPodDetailPage({super.key, required this.groupId});

  @override
  State<AdminPodDetailPage> createState() => _AdminPodDetailPageState();
}

class _AdminPodDetailPageState extends State<AdminPodDetailPage> {
  Map<String, dynamic>? _detail;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await KittyApi().adminGroup(widget.groupId);
      if (mounted) setState(() => _detail = r);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('load failed: $e')));
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'active':
        return KittyColors.moss;
      case 'recruiting':
      case 'awaiting_accepts':
        return KittyColors.coral;
      case 'chartered':
        return KittyColors.agentMatchmaker;
      case 'completed':
        return KittyColors.bowl;
      case 'forming_failed':
      case 'dissolved':
        return KittyColors.agentEmergency;
      default:
        return KittyColors.dusk;
    }
  }

  Color _memberStatusColor(String s) {
    switch (s) {
      case 'active':
      case 'received':
        return KittyColors.moss;
      case 'accepted':
        return KittyColors.agentMatchmaker;
      case 'invited':
        return KittyColors.coral;
      case 'declined':
      case 'defaulted':
      case 'emergency_exited':
        return KittyColors.agentEmergency;
      case 'exited_clean':
        return KittyColors.dusk;
      default:
        return KittyColors.dusk;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = _detail;
    return Scaffold(
      backgroundColor: KittyColors.cream,
      body: SafeArea(
        child: d == null
            ? const Center(
                child: CircularProgressIndicator(color: KittyColors.coral))
            : RefreshIndicator(
                color: KittyColors.coral,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 40),
                  children: [
                    _Header(
                      group: d['group'] as Map<String, dynamic>,
                      onBack: () => context.canPop()
                          ? context.pop()
                          : context.go('/admin'),
                      onEdit: () async {
                        final saved = await showEditCircleSheet(
                          context,
                          pod: d['group'] as Map<String, dynamic>,
                        );
                        if (saved) await _load();
                      },
                      statusColor: _statusColor,
                    ),
                    const SizedBox(height: 14),
                    _PodFactsCard(group: d['group'] as Map<String, dynamic>),
                    const SizedBox(height: 16),
                    _PodSummaryRow(detail: d),
                    const SizedBox(height: 20),
                    _SectionLabel('participants (${(d['members'] as List).length})'),
                    const SizedBox(height: 8),
                    ..._buildMemberRows(d, t),
                    const SizedBox(height: 22),
                    _SectionLabel('cycles'),
                    const SizedBox(height: 8),
                    _CyclesBlock(
                      groupId: widget.groupId,
                      cycles: List<Map<String, dynamic>>.from(d['cycles'] as List),
                      payouts: List<Map<String, dynamic>>.from(d['payouts'] as List),
                      members: List<Map<String, dynamic>>.from(d['members'] as List),
                      onResolved: _load,
                    ),
                    const SizedBox(height: 22),
                    _SectionLabel('recent events'),
                    const SizedBox(height: 8),
                    _EventStrip(
                      events:
                          List<Map<String, dynamic>>.from(d['events'] as List)
                              .take(20)
                              .toList(),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  List<Widget> _buildMemberRows(
    Map<String, dynamic> detail,
    TextTheme t,
  ) {
    final members =
        List<Map<String, dynamic>>.from(detail['members'] as List);
    final contribs =
        List<Map<String, dynamic>>.from(detail['contributions'] as List);
    // Group contributions by user_id, status='posted' counted+summed.
    final paidCountByUser = <String, int>{};
    final paidCentsByUser = <String, int>{};
    final pendingCountByUser = <String, int>{};
    for (final c in contribs) {
      final uid = c['user_id'] as String?;
      if (uid == null) continue;
      final status = c['status'] as String? ?? '';
      if (status == 'posted') {
        paidCountByUser[uid] = (paidCountByUser[uid] ?? 0) + 1;
        paidCentsByUser[uid] =
            (paidCentsByUser[uid] ?? 0) + ((c['amount_cents'] ?? 0) as int);
      } else if (status == 'pending') {
        pendingCountByUser[uid] = (pendingCountByUser[uid] ?? 0) + 1;
      }
    }
    return [
      for (var i = 0; i < members.length; i++)
        _MemberRow(
          member: members[i],
          paidCount: paidCountByUser[members[i]['user_id']] ?? 0,
          paidCents: paidCentsByUser[members[i]['user_id']] ?? 0,
          pendingCount: pendingCountByUser[members[i]['user_id']] ?? 0,
          memberStatusColor: _memberStatusColor,
        )
            .animate()
            .fadeIn(duration: 280.ms, delay: (40 * i).ms)
            .slideX(begin: 0.04),
    ];
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  final Map<String, dynamic> group;
  final VoidCallback onBack;
  final VoidCallback onEdit;
  final Color Function(String) statusColor;
  const _Header({
    required this.group,
    required this.onBack,
    required this.onEdit,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final status = (group['status'] as String?) ?? '';
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: onBack,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                group['name'] as String? ?? 'pod',
                style: t.headlineSmall?.copyWith(
                  color: KittyColors.bowl,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if ((group['theme'] as String?)?.isNotEmpty ?? false)
                Text(
                  group['theme'] as String,
                  style: t.bodySmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                  ),
                ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: statusColor(status).withValues(alpha: 0.15),
            borderRadius: const BorderRadius.all(KittyRadius.full),
          ),
          child: Text(
            status,
            style: t.labelSmall?.copyWith(
              color: statusColor(status),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          tooltip: 'edit pod',
          icon: const Icon(Icons.edit_rounded),
          onPressed: onEdit,
        ),
      ],
    );
  }
}

class _PodFactsCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _PodFactsCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fmt =
        NumberFormat.currency(locale: 'en_EU', symbol: '€', decimalDigits: 0);
    final amount = ((group['contribution_amount_cents'] ?? 0) as int) / 100;
    final cycleCount = group['cycle_count'] ?? 0;
    final pot = ((group['contribution_amount_cents'] ?? 0) as int) *
        ((group['cycle_count'] ?? 0) as int);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.all(KittyRadius.l),
        boxShadow: KittyShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((group['description'] as String?)?.isNotEmpty ?? false) ...[
            Text(group['description'] as String,
                style: t.bodyMedium?.copyWith(color: KittyColors.dusk)),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              _Fact(label: 'contribution', value: fmt.format(amount)),
              _Fact(label: 'cycles', value: '$cycleCount'),
              _Fact(label: 'pot', value: fmt.format(pot / 100)),
              _Fact(
                  label: 'min trust', value: '${group['min_trust_score'] ?? '?'}'),
              _Fact(
                  label: 'strategy',
                  value: (group['payout_strategy'] as String?) ?? 'rotation'),
              _Fact(
                  label: 'debit day',
                  value: '${group['debit_day'] ?? '?'}'),
              if ((group['cultural_hint'] as String?)?.isNotEmpty ?? false)
                _Fact(
                    label: 'culture',
                    value: group['cultural_hint'] as String),
              if ((group['accept_deadline'] as String?) != null)
                _Fact(
                    label: 'accept by',
                    value: _formatWhen(group['accept_deadline'] as String)),
              if ((group['starts_at'] as String?) != null)
                _Fact(
                    label: 'starts',
                    value: group['starts_at'] as String),
            ],
          ),
        ],
      ),
    );
  }
}

class _PodSummaryRow extends StatelessWidget {
  final Map<String, dynamic> detail;
  const _PodSummaryRow({required this.detail});

  @override
  Widget build(BuildContext context) {
    final members = List<Map<String, dynamic>>.from(detail['members'] as List);
    final contribs =
        List<Map<String, dynamic>>.from(detail['contributions'] as List);
    final payouts =
        List<Map<String, dynamic>>.from(detail['payouts'] as List);
    final cycles = List<Map<String, dynamic>>.from(detail['cycles'] as List);
    final accepted =
        members.where((m) => m['status'] == 'accepted').length;
    final active = members
        .where((m) => m['status'] == 'active' || m['status'] == 'received')
        .length;
    final invited = members.where((m) => m['status'] == 'invited').length;
    final postedCents = contribs
        .where((c) => c['status'] == 'posted')
        .fold<int>(0, (s, c) => s + ((c['amount_cents'] ?? 0) as int));
    final paidOutCents = payouts
        .where((p) => p['status'] == 'committed')
        .fold<int>(0, (s, p) => s + ((p['amount_cents'] ?? 0) as int));
    final paidCycles =
        cycles.where((c) => c['status'] == 'paid' || c['status'] == 'fallback').length;
    final fmt =
        NumberFormat.currency(locale: 'en_EU', symbol: '€', decimalDigits: 0);
    return Row(
      children: [
        Expanded(
            child: _StatPill(
                label: 'members',
                value: '${members.length}',
                sub: 'inv $invited · acc $accepted · act $active')),
        const SizedBox(width: 10),
        Expanded(
            child: _StatPill(
                label: 'collected', value: fmt.format(postedCents / 100))),
        const SizedBox(width: 10),
        Expanded(
            child: _StatPill(
                label: 'paid out',
                value: fmt.format(paidOutCents / 100),
                sub: '$paidCycles / ${cycles.length} cycles')),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  const _StatPill({required this.label, required this.value, this.sub});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.45),
        borderRadius: const BorderRadius.all(KittyRadius.m),
        border: const Border(
          left: BorderSide(color: KittyColors.coral, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: t.labelSmall?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.55),
                letterSpacing: 1.0,
              )),
          const SizedBox(height: 4),
          Text(value,
              style: t.titleMedium?.copyWith(
                color: KittyColors.bowl,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
          if (sub != null)
            Text(sub!,
                style: t.labelSmall?.copyWith(
                  color: KittyColors.dusk.withValues(alpha: 0.5),
                )),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              letterSpacing: 1.0,
            )),
        const SizedBox(height: 2),
        Text(value,
            style: t.bodyMedium?.copyWith(
              color: KittyColors.bowl,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final Map<String, dynamic> member;
  final int paidCount;
  final int paidCents;
  final int pendingCount;
  final Color Function(String) memberStatusColor;
  const _MemberRow({
    required this.member,
    required this.paidCount,
    required this.paidCents,
    required this.pendingCount,
    required this.memberStatusColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = (member['display_name'] as String?) ?? '?';
    final role = (member['role'] as String?) ?? 'member';
    final status = (member['status'] as String?) ?? '';
    final trust = member['trust_score'];
    final payoutCycle = member['payout_cycle'];
    final received = member['received_at'] != null;
    final fmt =
        NumberFormat.currency(locale: 'en_EU', symbol: '€', decimalDigits: 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.4),
          borderRadius: const BorderRadius.all(KittyRadius.m),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: KittyColors.bowl,
                shape: BoxShape.circle,
              ),
              child: Text(name.characters.first.toUpperCase(),
                  style: t.titleSmall?.copyWith(color: KittyColors.cream)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.titleSmall?.copyWith(
                              color: KittyColors.bowl,
                              fontWeight: FontWeight.w700,
                            )),
                      ),
                      if (role == 'admin') ...[
                        const SizedBox(width: 4),
                        const Text('★',
                            style: TextStyle(color: KittyColors.coral)),
                      ],
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    children: [
                      _Tag(
                        text: status,
                        color: memberStatusColor(status),
                      ),
                      if (trust != null) _Tag(text: 'trust $trust'),
                      if (payoutCycle != null)
                        _Tag(text: 'cycle $payoutCycle'),
                      if (received)
                        const _Tag(text: 'received', strong: true),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(fmt.format(paidCents / 100),
                    style: t.titleSmall?.copyWith(
                      color: KittyColors.bowl,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
                Text(
                  '$paidCount paid'
                  '${pendingCount > 0 ? ' · $pendingCount pending' : ''}',
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color? color;
  final bool strong;
  const _Tag({required this.text, this.color, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = color ?? KittyColors.dusk.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: strong ? 0.2 : 0.12),
        borderRadius: const BorderRadius.all(KittyRadius.full),
      ),
      child: Text(text,
          style: t.labelSmall?.copyWith(
            color: c,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
          )),
    );
  }
}

class _CyclesBlock extends StatelessWidget {
  final String groupId;
  final List<Map<String, dynamic>> cycles;
  final List<Map<String, dynamic>> payouts;
  final List<Map<String, dynamic>> members;
  final Future<void> Function() onResolved;
  const _CyclesBlock({
    required this.groupId,
    required this.cycles,
    required this.payouts,
    required this.members,
    required this.onResolved,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (cycles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'no cycles seeded yet',
          style: t.bodySmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.5),
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    final fmt =
        NumberFormat.currency(locale: 'en_EU', symbol: '€', decimalDigits: 0);
    final byUser = {
      for (final m in members) m['user_id'] as String: m['display_name'] as String? ?? '?',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.4),
        borderRadius: const BorderRadius.all(KittyRadius.l),
      ),
      child: Column(
        children: [
          for (var i = 0; i < cycles.length; i++) ...[
            _CycleRow(
              groupId: groupId,
              cycle: cycles[i],
              payouts: payouts,
              winnerName: byUser[cycles[i]['winner_user_id'] as String?],
              memberNamesById: byUser,
              fmt: fmt,
              onResolved: onResolved,
            ),
            if (i < cycles.length - 1)
              Divider(
                height: 1,
                color: KittyColors.dusk.withValues(alpha: 0.06),
              ),
          ],
        ],
      ),
    );
  }
}

class _CycleRow extends StatefulWidget {
  final String groupId;
  final Map<String, dynamic> cycle;
  final List<Map<String, dynamic>> payouts;
  final String? winnerName;
  final Map<String, String> memberNamesById;
  final NumberFormat fmt;
  final Future<void> Function() onResolved;
  const _CycleRow({
    required this.groupId,
    required this.cycle,
    required this.payouts,
    required this.winnerName,
    required this.memberNamesById,
    required this.fmt,
    required this.onResolved,
  });

  @override
  State<_CycleRow> createState() => _CycleRowState();
}

class _CycleRowState extends State<_CycleRow> {
  bool _busy = false;

  Future<void> _resolve(int month, String status) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KittyColors.cream,
        title: const Text('close bid window?'),
        content: Text(
          status == 'bid_window'
              ? 'Resolve cycle $month — pick the winner from current bids '
                  '(or fallback if none) and run the payout. Atomic, '
                  'irreversible.'
              : 'No bids placed yet for cycle $month — closing the window '
                  'will fall back to the rotation order and run the payout '
                  'immediately. Atomic, irreversible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: KittyColors.coral),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('close + pay out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await KittyApi().resolveCycle(widget.groupId, month);
      final winner = (r['winner_display_name'] as String?) ??
          widget.memberNamesById[r['winner_user_id'] as String?] ??
          'winner';
      final amount = ((r['amount_cents'] ?? 0) as int) / 100;
      final fee = ((r['fee_cents'] ?? 0) as int) / 100;
      final src = r['winner_source'] as String? ?? 'bid';
      final bunqId = r['bunq_payment_id'] as String?;
      final payoutStatus = r['payout_status'] as String?;
      final suspension = r['bunq_suspension'] as Map<String, dynamic>?;
      final String tail;
      final Color bg;
      if (payoutStatus == 'suspended') {
        final reason = (suspension?['reason'] as String?) ?? 'PENDING';
        tail = ' · bunq holding (#$bunqId · $reason)';
        bg = KittyColors.coral;
      } else if (bunqId != null) {
        tail = ' · paid via bunq (#$bunqId)';
        bg = KittyColors.bowl;
      } else {
        tail = ' · ledger-only (bunq leg pending)';
        bg = KittyColors.agentEmergency;
      }
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: bg,
          duration: const Duration(seconds: 6),
          content: Text(
            'cycle $month → $winner '
            '(€${amount.toStringAsFixed(0)} net · €${fee.toStringAsFixed(0)} fee · $src)$tail',
            style: const TextStyle(color: KittyColors.cream),
          ),
        ),
      );
      await widget.onResolved();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: KittyColors.agentEmergency,
          content: Text('resolve failed: $e',
              style: const TextStyle(color: KittyColors.cream)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final month = widget.cycle['cycle_month'] as int;
    final status = widget.cycle['status'] as String? ?? 'scheduled';
    final src = widget.cycle['winner_source'] as String?;
    final payoutForCycle = widget.payouts.firstWhere(
      (p) => p['cycle_month'] == month,
      orElse: () => <String, dynamic>{},
    );
    final amount = (payoutForCycle['amount_cents'] ?? 0) as int;
    final payoutStatus = payoutForCycle['status'] as String?;
    final bunqPaymentId = payoutForCycle['bunq_payment_id'] as String?;
    final bunqSuspension =
        payoutForCycle['bunq_suspension'] as Map<String, dynamic>?;
    final canResolve = status == 'bid_window' || status == 'contribution_window';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: KittyColors.cream,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$month',
                    style: t.titleSmall?.copyWith(
                      color: KittyColors.bowl,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.winnerName ?? '—',
                      style: t.titleSmall?.copyWith(color: KittyColors.bowl),
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        _Tag(text: status, color: _cycleStatusColor(status)),
                        if (src != null) _Tag(text: src),
                        if (payoutStatus != null)
                          _Tag(
                            text: _payoutStatusLabel(payoutStatus),
                            color: _payoutStatusColor(payoutStatus),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (amount > 0)
                Text(widget.fmt.format(amount / 100),
                    style: t.titleSmall?.copyWith(
                      color: payoutStatus == 'suspended'
                          ? KittyColors.coral
                          : KittyColors.moss,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
            ],
          ),
          if (bunqSuspension != null && payoutStatus == 'suspended') ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              decoration: BoxDecoration(
                color: KittyColors.coral.withValues(alpha: 0.10),
                borderRadius: const BorderRadius.all(KittyRadius.m),
                border: Border.all(
                  color: KittyColors.coral.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.hourglass_top_rounded,
                      size: 16, color: KittyColors.coral),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'bunq holding payment'
                          '${bunqPaymentId != null ? ' #$bunqPaymentId' : ''}'
                          ' · ${bunqSuspension['reason'] ?? 'PENDING'}',
                          style: t.labelMedium?.copyWith(
                            color: KittyColors.bowl,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'expected arrival: '
                          '${_formatWhen((bunqSuspension['expected_arrival'] as String?) ?? '')}',
                          style: t.labelSmall?.copyWith(
                            color: KittyColors.dusk.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (canResolve) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: KittyColors.coral,
                  foregroundColor: KittyColors.cream,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  textStyle: t.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: _busy ? null : () => _resolve(month, status),
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: KittyColors.cream,
                        ),
                      )
                    : const Icon(Icons.gavel_rounded, size: 16),
                label: Text(_busy
                    ? 'resolving…'
                    : (status == 'bid_window'
                        ? 'close bid window + pay out'
                        : 'close + pay out (no bids → fallback)')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _cycleStatusColor(String s) {
    switch (s) {
      case 'paid':
        return KittyColors.moss;
      case 'fallback':
        return KittyColors.coral;
      case 'bid_window':
      case 'contribution_window':
        return KittyColors.agentMatchmaker;
      case 'resolving':
        return KittyColors.coral;
      default:
        return KittyColors.dusk;
    }
  }

  String _payoutStatusLabel(String s) {
    switch (s) {
      case 'committed':
        return 'paid via bunq';
      case 'suspended':
        return 'bunq held';
      case 'pending':
        return 'ledger only';
      default:
        return s;
    }
  }

  Color _payoutStatusColor(String s) {
    switch (s) {
      case 'committed':
        return KittyColors.moss;
      case 'suspended':
        return KittyColors.coral;
      case 'pending':
        return KittyColors.agentEmergency;
      default:
        return KittyColors.dusk;
    }
  }
}

class _EventStrip extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  const _EventStrip({required this.events});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'no events recorded yet',
          style: t.bodySmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.5),
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.4),
        borderRadius: const BorderRadius.all(KittyRadius.l),
      ),
      child: Column(
        children: [
          for (final e in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(e['type'] as String? ?? '',
                        style: t.bodySmall?.copyWith(
                          color: KittyColors.dusk,
                          fontFamily: 'Menlo',
                        )),
                  ),
                  Text(_formatWhen(e['created_at'] as String? ?? ''),
                      style: t.labelSmall?.copyWith(
                        color: KittyColors.dusk.withValues(alpha: 0.5),
                      )),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2, left: 4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              letterSpacing: 1.4,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

String _formatWhen(String iso) {
  if (iso.isEmpty) return '';
  try {
    final dt = DateTime.parse(iso.replaceAll(' ', 'T')).toLocal();
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat.Hm().format(dt);
    }
    return DateFormat('MMM d HH:mm').format(dt);
  } catch (_) {
    return '';
  }
}
