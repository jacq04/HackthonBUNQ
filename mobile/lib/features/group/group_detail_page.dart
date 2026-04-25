import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../core/widgets/pot.dart';
import '../../services/api.dart';
import '../../services/supabase.dart';

class GroupDetailPage extends StatefulWidget {
  final String groupId;
  const GroupDetailPage({super.key, required this.groupId});

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> {
  Map<String, dynamic>? _group;
  List<dynamic>? _members;
  List<Map<String, dynamic>> _events = [];
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribe();
    _fetchEvents();
  }

  Future<void> _load() async {
    try {
      final r = await KittyApi().getGroup(widget.groupId);
      if (!mounted) return;
      setState(() {
        _group = r['group'] as Map<String, dynamic>;
        _members = r['members'] as List<dynamic>;
      });
    } catch (_) {/* noop */}
  }

  Future<void> _fetchEvents() async {
    final rows = await supabase
        .from('events')
        .select()
        .eq('group_id', widget.groupId)
        .order('created_at', ascending: false)
        .limit(50);
    if (mounted) setState(() => _events = List<Map<String, dynamic>>.from(rows));
  }

  /// Navigate to the bid screen for the latest open cycle in this group.
  /// Silently falls back to the group detail if no cycle is open.
  Future<void> _gotoBid() async {
    final cycles = await supabase
        .from('cycles')
        .select('cycle_month,status')
        .eq('group_id', widget.groupId)
        .inFilter('status', ['contribution_window', 'bid_window'])
        .order('cycle_month')
        .limit(1);
    if (!mounted || (cycles as List).isEmpty) return;
    final m = (cycles as List).first as Map;
    final pot = ((_group?['contribution_amount_cents'] ?? 0) as int) *
        ((_group?['cycle_count'] ?? 0) as int);
    if (!mounted) return;
    context.push(
      '/group/${widget.groupId}/cycle/${m['cycle_month']}/bid?pot=$pot',
    );
  }

  void _subscribe() {
    _channel = supabase
        .channel('events:${widget.groupId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: widget.groupId,
          ),
          callback: (payload) {
            if (!mounted) return;
            setState(() {
              _events = [Map<String, dynamic>.from(payload.newRecord), ..._events].take(50).toList();
            });
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) supabase.removeChannel(_channel!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final g = _group;
    final filled = _events
        .where((e) => e['type'] == 'contribution.posted')
        .fold<int>(0, (s, e) => s + ((e['payload']?['amount_cents'] ?? 0) as int));
    final target = g == null ? 1 : ((g['contribution_amount_cents'] as int) * (g['cycle_count'] as int));

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(group: g, onClose: () => context.pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 120),
                children: [
                  if (g != null) _LifecycleBanner(group: g, members: _members ?? const []),
                  const SizedBox(height: 16),
                  Center(
                    child: Hero(
                      tag: 'pot-${widget.groupId}',
                      child: Pot(
                        filled: target == 0 ? 0 : filled / target,
                        size: 260,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Column(
                      children: [
                        Text('€${(filled / 100).toStringAsFixed(0)}',
                            style: t.displaySmall?.copyWith(
                                color: KittyColors.bowl,
                                fontFeatures: const [FontFeature.tabularFigures()])),
                        Text('of €${(target / 100).toStringAsFixed(0)}',
                            style: t.bodyMedium?.copyWith(
                                color: KittyColors.dusk.withValues(alpha: 0.5))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (_members != null) _MembersCard(members: _members!),
                  const SizedBox(height: 20),
                  _LedgerCard(events: _events),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: CoralButton(
                        label: (_group?['status'] == 'active') ? 'place bid' : 'contribute',
                        hero: true,
                        onPressed: _group?['status'] == 'active'
                            ? () => _gotoBid()
                            : () {/* TODO contribute */},
                        leading: Text(
                          _group?['status'] == 'active' ? '🎯' : '💳',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    CoralButton(
                      label: 'dispute',
                      color: KittyColors.agentMediator,
                      onPressed: () {/* TODO */},
                    ),
                    const SizedBox(width: 10),
                    CoralButton(
                      label: 'exit',
                      color: KittyColors.agentEmergency,
                      onPressed: () {/* TODO */},
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Adapts the call-to-action based on the circle's current lifecycle state.
/// For `awaiting_accepts` AND the current user is still `invited`, shows an
/// accept banner that routes to /accept. For active circles, shows a compact
/// status chip with the state.
class _LifecycleBanner extends StatelessWidget {
  final Map<String, dynamic> group;
  final List<dynamic> members;
  const _LifecycleBanner({required this.group, required this.members});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final status = group['status'] as String? ?? '';
    final myId = supabase.auth.currentUser?.id;
    final me = members.cast<Map<String, dynamic>>().firstWhere(
          (m) => m['user_id'] == myId,
          orElse: () => <String, dynamic>{},
        );
    final myStatus = me['status'] as String?;
    final accepted =
        members.where((m) => m['status'] == 'accepted').length;
    final target = group['cycle_count'] as int? ?? 0;

    if (status == 'awaiting_accepts' && myStatus == 'invited') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                KittyColors.coral.withValues(alpha: 0.9),
                KittyColors.ember.withValues(alpha: 0.85),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.all(KittyRadius.xl),
            boxShadow: KittyShadows.lift,
          ),
          child: Row(
            children: [
              const Text('✉️', style: TextStyle(fontSize: 32)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "you're invited",
                      style: t.titleMedium?.copyWith(
                        color: KittyColors.cream,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '$accepted of $target accepted so far',
                      style: t.bodySmall?.copyWith(
                        color: KittyColors.cream.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
              CoralButton(
                label: 'review',
                color: KittyColors.cream,
                foreground: KittyColors.bowl,
                onPressed: () =>
                    context.push('/group/${group['id']}/accept'),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 420.ms).slideY(begin: 0.1),
      );
    }

    if (status == 'awaiting_accepts') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
        child: Text(
          'awaiting accepts — $accepted of $target in',
          style: t.bodySmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.6),
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    if (status == 'chartered') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
        child: Text(
          'chartered — waiting for platform to start the first cycle',
          style: t.bodySmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.6),
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}


class _Header extends StatelessWidget {
  final Map<String, dynamic>? group;
  final VoidCallback onClose;
  const _Header({required this.group, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.close_rounded), onPressed: onClose),
          Expanded(
            child: Center(
              child: Column(
                children: [
                  Text(group?['name'] ?? '…',
                      style: t.headlineMedium?.copyWith(color: KittyColors.bowl)),
                  if (group != null)
                    Text(
                      '€${((group!['contribution_amount_cents'] ?? 0) / 100).toStringAsFixed(0)}  ·  '
                      '${group!['cycle_count']} cycles  ·  ${group!['status']}',
                      style: t.bodySmall?.copyWith(
                        color: KittyColors.dusk.withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _MembersCard extends StatelessWidget {
  final List<dynamic> members;
  const _MembersCard({required this.members});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.7),
          borderRadius: const BorderRadius.all(KittyRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Text('MEMBERS (${members.length})',
                  style: t.labelSmall?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.55))),
            ),
            ...members.asMap().entries.map((e) {
              final i = e.key;
              final m = e.value as Map<String, dynamic>;
              final u = m['users'] as Map<String, dynamic>? ?? {};
              final name = (u['display_name'] as String?) ?? '?';
              final admin = m['role'] == 'admin';
              return _MemberRow(name: name, admin: admin, cycle: m['payout_cycle'] as int?)
                  .animate()
                  .fadeIn(duration: 320.ms, delay: (60 * i).ms)
                  .slideX(begin: -0.06);
            }),
          ],
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final String name;
  final bool admin;
  final int? cycle;
  const _MemberRow({required this.name, required this.admin, required this.cycle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(color: KittyColors.bowl, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(name.characters.first.toUpperCase(),
                style: t.labelLarge?.copyWith(color: KittyColors.cream)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: name,
                    style: t.titleSmall?.copyWith(color: KittyColors.dusk, fontWeight: FontWeight.w600)),
                if (admin)
                  const TextSpan(
                      text: '  ★', style: TextStyle(color: KittyColors.coral, fontSize: 14)),
              ]),
            ),
          ),
          if (cycle != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: KittyColors.cream,
                borderRadius: const BorderRadius.all(KittyRadius.full),
              ),
              child: Text('cycle $cycle',
                  style: t.labelSmall?.copyWith(color: KittyColors.bowl)),
            ),
        ],
      ),
    );
  }
}

class _LedgerCard extends StatelessWidget {
  final List<Map<String, dynamic>> events;
  const _LedgerCard({required this.events});

  String _describe(Map<String, dynamic> e) {
    final p = e['payload'] as Map<String, dynamic>? ?? {};
    final amt = (p['amount_cents'] ?? 0) as int;
    switch (e['type']) {
      case 'contribution.posted':
        return 'contribution posted — €${(amt / 100).toStringAsFixed(0)} · cycle ${p['cycle_month'] ?? ''}';
      case 'contribution.pending':
        return 'contribution pending — €${(amt / 100).toStringAsFixed(0)}';
      case 'payout.committed':
        return 'payout committed — €${(amt / 100).toStringAsFixed(0)}';
      case 'payout.ledger_only':
        return 'payout on ledger — €${(amt / 100).toStringAsFixed(0)} (bunq pending)';
      case 'dispute.resolved':
        return 'dispute resolved — ${p['verdict'] ?? ''}';
      case 'emergency.executed':
        return 'emergency refund — €${((p['refund_cents'] ?? 0) as int) / 100}';
      case 'matchmaker.formed':
        return 'circle formed by matchmaker';
      case 'charter.finalized':
        return 'charter finalized';
      default:
        return (e['type'] as String?) ?? '';
    }
  }

  String _icon(String type) => switch (type) {
        'contribution.posted' => '✓',
        'contribution.pending' => '⋯',
        'payout.committed' => '◈',
        'payout.ledger_only' => '◇',
        'dispute.resolved' => '⚖',
        'emergency.proposed' => '!',
        'emergency.executed' => '→',
        'matchmaker.formed' => '✨',
        'charter.finalized' => '★',
        _ => '·',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.7),
          borderRadius: const BorderRadius.all(KittyRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text('LEDGER TAPE',
                  style: t.labelSmall?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.55))),
            ),
            if (events.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('the tape starts empty — nothing has moved yet',
                    textAlign: TextAlign.center,
                    style: t.bodySmall?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.45),
                      fontStyle: FontStyle.italic,
                    )),
              )
            else
              ...events.take(12).map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      SizedBox(
                        width: 22,
                        child: Text(_icon(e['type'] as String),
                            style: const TextStyle(color: KittyColors.coral, fontSize: 15)),
                      ),
                      Expanded(
                        child: Text(
                          _describe(e),
                          style: t.bodySmall?.copyWith(color: KittyColors.dusk),
                        ),
                      ),
                    ]),
                  )),
          ],
        ),
      ),
    );
  }
}
