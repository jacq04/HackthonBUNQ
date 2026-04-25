import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../core/widgets/piggy.dart';
import '../../services/api.dart';
import '../../services/supabase.dart';

class GroupDetailPage extends StatefulWidget {
  final String groupId;
  const GroupDetailPage({super.key, required this.groupId});

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends State<GroupDetailPage> with WidgetsBindingObserver {
  Map<String, dynamic>? _group;
  List<dynamic>? _members;
  List<Map<String, dynamic>> _events = [];
  int _myPayments = 0;
  int _myContribCents = 0;
  int _cyclesDone = 0;
  RealtimeChannel? _channel;
  RealtimeChannel? _groupChannel;
  RealtimeChannel? _membersChannel;
  RealtimeChannel? _cyclesChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _subscribe();
    _subscribeGroupAndMembers();
    _subscribeProgress();
    _fetchEvents();
    _fetchProgress();
  }

  /// Refresh when the app window comes back to foreground (e.g. after the
  /// user accepted their invite and popped back).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  /// Realtime push for group.status changes + member accepts so the lifecycle
  /// banner reflects progress without a manual refresh.
  void _subscribeGroupAndMembers() {
    _groupChannel = supabase
        .channel('group:${widget.groupId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'groups',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: widget.groupId,
          ),
          callback: (_) => _load(),
        )
        .subscribe();
    _membersChannel = supabase
        .channel('members:${widget.groupId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'members',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: widget.groupId,
          ),
          callback: (_) => _load(),
        )
        .subscribe();
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

  /// Compute the two anonymous progress metrics:
  ///   - myPayments: how many distinct cycles this signed-in user already
  ///     has a `posted` contribution in.
  ///   - cyclesDone: how many cycles in this group reached a payout
  ///     (`paid` or `fallback`).
  Future<void> _fetchProgress() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final mine = await supabase
          .from('contributions')
          .select('cycle_month,amount_cents')
          .eq('group_id', widget.groupId)
          .eq('user_id', uid)
          .eq('status', 'posted');
      final mineList = List<Map<String, dynamic>>.from(mine);
      final myMonths =
          mineList.map((r) => r['cycle_month'] as int).toSet();
      final myCents = mineList.fold<int>(
        0,
        (s, r) => s + ((r['amount_cents'] ?? 0) as int),
      );

      final paid = await supabase
          .from('cycles')
          .select('cycle_month, status')
          .eq('group_id', widget.groupId)
          .inFilter('status', ['paid', 'fallback']);
      final paidList = List<Map<String, dynamic>>.from(paid);

      if (!mounted) return;
      setState(() {
        _myPayments = myMonths.length;
        _myContribCents = myCents;
        _cyclesDone = paidList.length;
      });
    } catch (_) {/* swallow — card just shows 0/0 until next refresh */}
  }

  /// Realtime: refetch progress whenever this user posts a contribution
  /// or any cycle resolves. Cheaper than re-running _load on every event.
  void _subscribeProgress() {
    _cyclesChannel = supabase
        .channel('cycles:${widget.groupId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'cycles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: widget.groupId,
          ),
          callback: (_) => _fetchProgress(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'contributions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: widget.groupId,
          ),
          callback: (_) => _fetchProgress(),
        )
        .subscribe();
  }

  Future<void> _fetchEvents() async {
    final rows = await supabase
        .from('events')
        .select()
        .eq('group_id', widget.groupId)
        .order('created_at', ascending: false)
        .limit(50);
    final list = List<Map<String, dynamic>>.from(rows);
    final seen = <Object?>{};
    final deduped = [
      for (final r in list)
        if (seen.add(r['id'])) r,
    ];
    if (mounted) setState(() => _events = deduped);
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
            final row = Map<String, dynamic>.from(payload.newRecord);
            final id = row['id'];
            // Race: this same row may already have been pulled in by the
            // initial _fetchEvents query, or by a previous realtime tick if
            // the subscription resubscribes. Dedupe by id.
            setState(() {
              _events = [
                row,
                ..._events.where((e) => e['id'] != id),
              ].take(50).toList();
            });
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_channel != null) supabase.removeChannel(_channel!);
    if (_groupChannel != null) supabase.removeChannel(_groupChannel!);
    if (_membersChannel != null) supabase.removeChannel(_membersChannel!);
    if (_cyclesChannel != null) supabase.removeChannel(_cyclesChannel!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final g = _group;
    // The piggy reflects how much THIS user has chipped in across cycles.
    // It only ever grows — read from the contributions table (authoritative)
    // not from the events tape which is capped to the latest 50 rows.
    final filled = _myContribCents;
    final target = g == null
        ? 1
        : ((g['contribution_amount_cents'] as int) * (g['cycle_count'] as int));

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              group: g,
              onClose: () => context.canPop() ? context.pop() : context.go('/'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 120),
                children: [
                  if (g != null) _LifecycleBanner(group: g, members: _members ?? const []),
                  const SizedBox(height: 16),
                  Center(
                    child: Hero(
                      tag: 'piggy-${widget.groupId}',
                      child: Piggy(
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
                  if (g != null)
                    _ProgressCard(
                      cycleCount: (g['cycle_count'] ?? 0) as int,
                      myPayments: _myPayments,
                      cyclesDone: _cyclesDone,
                    ),
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
                onPressed: () async {
                  // Accept page pops with `true` on success. Capture the
                  // ancestor state BEFORE the await so we don't reach for
                  // context after a possible widget teardown.
                  final state = context
                      .findAncestorStateOfType<_GroupDetailPageState>();
                  final r =
                      await context.push('/group/${group['id']}/accept');
                  if (r == true) {
                    state?._load();
                    state?._fetchEvents();
                  }
                },
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

/// Anonymous circle-progress card. Members stay private — the card surfaces
/// only what matters to the signed-in user: how many cycles they have already
/// contributed in, and how many cycles are left in the rotation.
class _ProgressCard extends StatelessWidget {
  final int cycleCount;
  final int myPayments;
  final int cyclesDone;
  const _ProgressCard({
    required this.cycleCount,
    required this.myPayments,
    required this.cyclesDone,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final remaining = (cycleCount - cyclesDone).clamp(0, cycleCount);
    final paymentsMade = myPayments.clamp(0, cycleCount);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.7),
          borderRadius: const BorderRadius.all(KittyRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10),
              child: Text(
                'CIRCLE PROGRESS',
                style: t.labelSmall?.copyWith(
                  color: KittyColors.dusk.withValues(alpha: 0.55),
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _ProgressStat(
                    label: 'your payments',
                    value: '$paymentsMade',
                    sub: 'of $cycleCount',
                  ),
                ),
                Container(
                  width: 1,
                  height: 44,
                  color: KittyColors.dusk.withValues(alpha: 0.08),
                ),
                Expanded(
                  child: _ProgressStat(
                    label: 'cycles remaining',
                    value: '$remaining',
                    sub: 'of $cycleCount',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: cycleCount == 0 ? 0 : paymentsMade / cycleCount,
                minHeight: 8,
                backgroundColor: KittyColors.dusk.withValues(alpha: 0.08),
                valueColor: const AlwaysStoppedAnimation(KittyColors.coral),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 380.ms).slideY(begin: 0.08);
  }
}

class _ProgressStat extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  const _ProgressStat({
    required this.label,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: t.bodySmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: t.headlineMedium?.copyWith(
            color: KittyColors.bowl,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          sub,
          style: t.labelSmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.45),
          ),
        ),
      ],
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
      case 'payout.bunq_suspended':
        final sus = p['bunq_suspension'] as Map<String, dynamic>? ?? {};
        final reason = sus['reason'] as String? ?? 'PENDING';
        return 'bunq holding payout — €${(amt / 100).toStringAsFixed(0)} ($reason)';
      case 'payout.ledger_only':
        return 'payout on ledger — €${(amt / 100).toStringAsFixed(0)} (bunq pending)';
      case 'dispute.resolved':
        return 'dispute resolved — ${p['verdict'] ?? ''}';
      case 'emergency.executed':
        return 'emergency refund — €${((p['refund_cents'] ?? 0) as int) / 100}';
      case 'matchmaker.formed':
        return 'pod formed by matchmaker';
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
        'payout.bunq_suspended' => '⏳',
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
