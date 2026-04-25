import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/pod_wordmark.dart';
import '../../core/widgets/talk_to_pod_button.dart';
import '../../services/api.dart';
import '../../services/supabase.dart';
import '../wallet/account_card.dart';
import '../wallet/transaction_tile.dart';
import 'create_circle_sheet.dart';

/// Operator control room: a tabbed dashboard that surfaces every circle,
/// every cycle, every agent tool call, every event in the system. Bypasses
/// RLS via the backend's service-role client. In hackathon mode any
/// authenticated user can open it; production would gate by role.
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  Map<String, dynamic>? _overview;
  List<Map<String, dynamic>>? _groups;
  List<Map<String, dynamic>>? _waitlist;
  List<Map<String, dynamic>>? _audit;
  List<Map<String, dynamic>>? _agentMsgs;
  List<Map<String, dynamic>>? _events;
  List<Map<String, dynamic>>? _platformAccounts;
  List<Map<String, dynamic>>? _platformTxs;
  RealtimeChannel? _eventChan;
  RealtimeChannel? _auditChan;
  Timer? _poll;
  Timer? _balancePoll;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 6, vsync: this);
    _loadAll();
    _subscribe();
    // Light polling as a belt for realtime — overview counters change after
    // contributions/payouts and we want the totals to drift live.
    _poll = Timer.periodic(const Duration(seconds: 12), (_) => _loadOverview());
    // Refresh the bunq balance separately on a slower cadence — bunq rate
    // limits matter and the account doesn't move per-second.
    _balancePoll = Timer.periodic(
        const Duration(seconds: 30), (_) => _loadPlatformAccount());
  }

  @override
  void dispose() {
    _tab.dispose();
    _poll?.cancel();
    _balancePoll?.cancel();
    if (_eventChan != null) supabase.removeChannel(_eventChan!);
    if (_auditChan != null) supabase.removeChannel(_auditChan!);
    super.dispose();
  }

  void _subscribe() {
    _eventChan = supabase
        .channel('admin:events')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'events',
          callback: (p) {
            if (!mounted) return;
            setState(() {
              _events = [
                Map<String, dynamic>.from(p.newRecord),
                ...?_events,
              ].take(200).toList();
            });
            _loadOverview();
          },
        )
        .subscribe();
    _auditChan = supabase
        .channel('admin:audit')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'audit_log',
          callback: (p) {
            if (!mounted) return;
            setState(() {
              _audit = [
                Map<String, dynamic>.from(p.newRecord),
                ...?_audit,
              ].take(200).toList();
            });
          },
        )
        .subscribe();
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadOverview(),
      _loadGroups(),
      _loadWaitlist(),
      _loadAudit(),
      _loadAgentMessages(),
      _loadEvents(),
      _loadPlatformAccount(),
    ]);
  }

  /// Pulls the signed-in admin's own bunq accounts — for Asha that's the
  /// platform collection account, so contributions land here.
  Future<void> _loadPlatformAccount() async {
    try {
      final results = await Future.wait([
        KittyApi().myAccounts(),
        KittyApi().myTransactions(days: 14),
      ]);
      if (!mounted) return;
      setState(() {
        _platformAccounts = List<Map<String, dynamic>>.from(results[0]);
        _platformTxs = List<Map<String, dynamic>>.from(results[1]);
      });
    } catch (_) {/* ignore */}
  }

  Future<void> _loadWaitlist() async {
    try {
      final r = await KittyApi().adminWaitlist();
      if (mounted) setState(() => _waitlist = r);
    } catch (_) {/* ignore */}
  }

  Future<void> _loadOverview() async {
    try {
      final r = await KittyApi().adminOverview();
      if (mounted) setState(() => _overview = r);
    } catch (_) {/* ignore */}
  }

  Future<void> _loadGroups() async {
    try {
      final r = await KittyApi().adminGroups();
      if (mounted) setState(() => _groups = r);
    } catch (_) {/* ignore */}
  }

  Future<void> _loadAudit() async {
    try {
      final r = await KittyApi().adminAudit(limit: 200);
      if (mounted) setState(() => _audit = r);
    } catch (_) {/* ignore */}
  }

  Future<void> _loadAgentMessages() async {
    try {
      final r = await KittyApi().adminAgentMessages(limit: 200);
      if (mounted) setState(() => _agentMsgs = r);
    } catch (_) {/* ignore */}
  }

  Future<void> _loadEvents() async {
    try {
      final r = await KittyApi().adminEvents(limit: 200);
      if (mounted) setState(() => _events = r);
    } catch (_) {/* ignore */}
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: KittyColors.creamDark,
      body: Stack(children: [
        SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 16, 0),
              child: Row(
                children: [
                  if (context.canPop())
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => context.pop(),
                    )
                  else
                    const SizedBox(width: 8),
                  const SizedBox(width: 4),
                  const PodWordmark(size: 36),
                  const SizedBox(width: 12),
                  Text('control room',
                      style: t.titleMedium?.copyWith(
                        color: KittyColors.bowl,
                        fontWeight: FontWeight.w700,
                      )),
                  const Spacer(),
                  IconButton(
                    tooltip: 'refresh',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: _loadAll,
                  ),
                  IconButton(
                    tooltip: 'sign out',
                    icon: const Icon(Icons.logout_rounded),
                    onPressed: () async {
                      await supabase.auth.signOut();
                      if (context.mounted) context.go('/sign-in');
                    },
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tab,
              isScrollable: true,
              labelColor: KittyColors.bowl,
              unselectedLabelColor: KittyColors.dusk.withValues(alpha: 0.55),
              indicatorColor: KittyColors.coral,
              tabs: const [
                Tab(text: 'overview'),
                Tab(text: 'pods'),
                Tab(text: 'waitlist'),
                Tab(text: 'agents'),
                Tab(text: 'audit'),
                Tab(text: 'events'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  _OverviewTab(
                    overview: _overview,
                    platformAccounts: _platformAccounts,
                    platformTxs: _platformTxs,
                    onRefresh: _loadAll,
                  ),
                  _CirclesTab(groups: _groups, onRefresh: _loadGroups),
                  _WaitlistTab(waitlist: _waitlist, onRefresh: _loadWaitlist),
                  _AgentsTab(
                    overview: _overview,
                    messages: _agentMsgs,
                    audit: _audit,
                    onRefresh: () async {
                      await Future.wait([_loadAgentMessages(), _loadAudit()]);
                    },
                  ),
                  _AuditTab(audit: _audit, onRefresh: _loadAudit),
                  _EventsTab(events: _events, onRefresh: _loadEvents),
                ],
              ),
            ),
          ],
        ),
        ),
        const TalkToPodButton(bottomInset: 28),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Overview tab
// ─────────────────────────────────────────────────────────────────────────────
class _OverviewTab extends StatelessWidget {
  final Map<String, dynamic>? overview;
  final List<Map<String, dynamic>>? platformAccounts;
  final List<Map<String, dynamic>>? platformTxs;
  final Future<void> Function() onRefresh;
  const _OverviewTab({
    required this.overview,
    required this.platformAccounts,
    required this.platformTxs,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (overview == null) {
      return const Center(child: CircularProgressIndicator(color: KittyColors.coral));
    }
    final t = Theme.of(context).textTheme;
    final circles = overview!['circles'] as Map? ?? {};
    final money = overview!['money'] as Map? ?? {};
    final cycles = overview!['cycles'] as Map? ?? {};
    final agents = (overview!['agents'] as List?) ?? const [];
    final fmt = NumberFormat.currency(locale: 'en_EU', symbol: '€', decimalDigits: 2);
    return RefreshIndicator(
      color: KittyColors.coral,
      onRefresh: onRefresh,
      child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        _SectionLabel('platform account'),
        _PlatformAccountSection(
          accounts: platformAccounts,
          txs: platformTxs,
        ),
        const SizedBox(height: 22),
        _SectionLabel('pods'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatTile(label: 'total', value: '${circles['total'] ?? 0}'),
            _StatTile(
                label: 'active',
                value: '${circles['active'] ?? 0}',
                accent: KittyColors.moss),
            _StatTile(
                label: 'recruiting',
                value: '${circles['recruiting'] ?? 0}',
                accent: KittyColors.coral),
            _StatTile(label: 'awaiting', value: '${circles['awaiting_accepts'] ?? 0}'),
            _StatTile(label: 'chartered', value: '${circles['chartered'] ?? 0}'),
          ],
        ),
        const SizedBox(height: 22),
        _SectionLabel('cycles'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatTile(label: 'total', value: '${cycles['total'] ?? 0}'),
            _StatTile(
                label: 'paid',
                value: '${cycles['paid'] ?? 0}',
                accent: KittyColors.moss),
            _StatTile(label: 'fallback', value: '${cycles['fallback'] ?? 0}'),
          ],
        ),
        const SizedBox(height: 22),
        _SectionLabel('money flow'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatTile(
              label: 'contributions',
              value: '${money['contributions_posted'] ?? 0}',
              sub: fmt.format(((money['contributions_eur_cents'] ?? 0) as int) / 100),
            ),
            _StatTile(
              label: 'payouts',
              value: '${money['payouts_committed'] ?? 0}',
              sub: fmt.format(((money['payouts_eur_cents'] ?? 0) as int) / 100),
              accent: KittyColors.moss,
            ),
            _StatTile(label: 'bids', value: '${overview!['bids_total'] ?? 0}'),
            _StatTile(
                label: 'members', value: '${overview!['members_total'] ?? 0}'),
          ],
        ),
        const SizedBox(height: 22),
        _SectionLabel('agent activity'),
        if (agents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'no agent calls recorded yet',
              style: t.bodySmall?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          ...agents.map((a) => _AgentRollupRow(a as Map<String, dynamic>)),
      ],
      ),
    );
  }
}

class _PlatformAccountSection extends StatelessWidget {
  final List<Map<String, dynamic>>? accounts;
  final List<Map<String, dynamic>>? txs;
  const _PlatformAccountSection({required this.accounts, required this.txs});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (accounts == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
            child: CircularProgressIndicator(color: KittyColors.coral)),
      );
    }
    if (accounts!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'no bunq account linked — run the bunq bootstrap',
          style: t.bodySmall?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.55),
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    final primary = accounts!.first;
    final txList = (txs ?? const []).take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: AccountCard(
            description: (primary['description'] as String?) ??
                'platform collection',
            iban: primary['iban'] as String?,
            balanceCents: primary['balance_cents'] as int? ?? 0,
            currency: primary['currency'] as String? ?? 'EUR',
            paletteIndex: primary['palette_index'] as int? ?? 0,
            width: 340,
            height: 200,
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'RECENT INFLOWS',
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              letterSpacing: 1.2,
            ),
          ),
        ),
        if (txList.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'no payments in the last 14 days',
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: KittyColors.soft.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.all(KittyRadius.l),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < txList.length; i++) ...[
                  TransactionTile(tx: txList[i]),
                  if (i < txList.length - 1)
                    Divider(
                      height: 1,
                      color: KittyColors.dusk.withValues(alpha: 0.06),
                      indent: 68,
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? accent;
  const _StatTile({
    required this.label,
    required this.value,
    this.sub,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      width: 158,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.6),
        borderRadius: const BorderRadius.all(KittyRadius.l),
        border: Border(
          left: BorderSide(color: accent ?? KittyColors.bowl, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: t.headlineMedium?.copyWith(
              color: KittyColors.bowl,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (sub != null)
            Text(sub!,
                style: t.bodySmall?.copyWith(
                  color: KittyColors.dusk.withValues(alpha: 0.55),
                )),
        ],
      ),
    );
  }
}

class _AgentRollupRow extends StatelessWidget {
  final Map<String, dynamic> data;
  const _AgentRollupRow(this.data);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final agent = data['agent'] as String? ?? '?';
    final calls = data['calls'] as int? ?? 0;
    final fails = data['fails'] as int? ?? 0;
    final actions = (data['actions'] as Map?) ?? {};
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.45),
          borderRadius: const BorderRadius.all(KittyRadius.l),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: KittyColors.coral,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(agent,
                    style: t.titleSmall?.copyWith(
                      color: KittyColors.bowl,
                      fontWeight: FontWeight.w700,
                    )),
                const Spacer(),
                Text('$calls calls',
                    style: t.bodySmall?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.6),
                    )),
                if (fails > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: KittyColors.agentEmergency.withValues(alpha: 0.15),
                      borderRadius: const BorderRadius.all(KittyRadius.full),
                    ),
                    child: Text('$fails failed',
                        style: t.labelSmall?.copyWith(
                          color: KittyColors.agentEmergency,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: actions.entries
                  .map((e) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: KittyColors.cream,
                          borderRadius:
                              const BorderRadius.all(KittyRadius.full),
                        ),
                        child: Text('${e.key} · ${e.value}',
                            style: t.labelSmall
                                ?.copyWith(color: KittyColors.bowl)),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Circles tab
// ─────────────────────────────────────────────────────────────────────────────
class _CirclesTab extends StatelessWidget {
  final List<Map<String, dynamic>>? groups;
  final Future<void> Function() onRefresh;
  const _CirclesTab({required this.groups, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (groups == null) {
      return const Center(child: CircularProgressIndicator(color: KittyColors.coral));
    }
    return Stack(
      children: [
        if (groups!.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 80),
              child: Text(
                'no pods yet — tap + to open one',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55)),
              ),
            ),
          )
        else
          RefreshIndicator(
            color: KittyColors.coral,
            onRefresh: onRefresh,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 100),
              itemCount: groups!.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _CircleAdminCard(
                group: groups![i],
                onChanged: onRefresh,
              )
                  .animate()
                  .fadeIn(duration: 300.ms, delay: (40 * i).ms)
                  .slideY(begin: 0.04),
            ),
          ),
        Positioned(
          right: 20,
          bottom: 20,
          child: FloatingActionButton.extended(
            backgroundColor: KittyColors.coral,
            foregroundColor: KittyColors.cream,
            icon: const Icon(Icons.add_rounded),
            label: const Text('open pod'),
            onPressed: () async {
              final created = await showCreateCircleSheet(context);
              if (created) await onRefresh();
            },
          ),
        ),
      ],
    );
  }
}

class _CircleAdminCard extends StatelessWidget {
  final Map<String, dynamic> group;
  final Future<void> Function() onChanged;
  const _CircleAdminCard({required this.group, required this.onChanged});

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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final status = (group['status'] as String?) ?? '';
    final amount = ((group['contribution_amount_cents'] ?? 0) as int) / 100;
    final cycleCount = group['cycle_count'] ?? 0;
    final cyclesPaid = group['cycles_paid'] ?? 0;
    final cyclesOpen = group['cycles_open'] ?? 0;
    final mTotal = group['members_total'] ?? 0;
    final mAccepted = group['members_accepted'] ?? 0;
    final mActive = group['members_active'] ?? 0;
    final contribs = group['contributions_posted'] ?? 0;
    final fmt = NumberFormat.currency(locale: 'en_EU', symbol: '€', decimalDigits: 0);
    return InkWell(
      borderRadius: const BorderRadius.all(KittyRadius.l),
      onTap: () async {
        await context.push('/admin/pods/${group['id']}');
        // Refresh on return so any edits made on the deep-dive page propagate.
        await onChanged();
      },
      child: Ink(
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.55),
          borderRadius: const BorderRadius.all(KittyRadius.l),
          boxShadow: KittyShadows.card,
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(group['name'] ?? '',
                      style: t.titleMedium?.copyWith(
                        color: KittyColors.bowl,
                        fontWeight: FontWeight.w700,
                      )),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withValues(alpha: 0.15),
                    borderRadius: const BorderRadius.all(KittyRadius.full),
                  ),
                  child: Text(status,
                      style: t.labelSmall?.copyWith(
                        color: _statusColor(status),
                        fontWeight: FontWeight.w700,
                      )),
                ),
                IconButton(
                  tooltip: 'edit pod',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  onPressed: () async {
                    final saved =
                        await showEditCircleSheet(context, pod: group);
                    if (saved) await onChanged();
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${fmt.format(amount)} × $cycleCount cycles'
              '${group['theme'] != null ? '  ·  ${group['theme']}' : ''}'
              '  ·  min trust ${group['min_trust_score'] ?? '?'}',
              style: t.bodySmall?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.6),
              ),
            ),
            if ((group['description'] as String?)?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  group['description'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.5),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _MiniMetric(label: 'members', value: '$mTotal'),
                _MiniMetric(label: 'accepted', value: '$mAccepted'),
                _MiniMetric(label: 'active', value: '$mActive'),
                _MiniMetric(label: 'contribs', value: '$contribs'),
                _MiniMetric(label: 'cycles paid', value: '$cyclesPaid'),
                _MiniMetric(label: 'cycles open', value: '$cyclesOpen'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;
  const _MiniMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: t.titleSmall?.copyWith(
              color: KittyColors.bowl,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
        const SizedBox(width: 4),
        Text(label,
            style: t.labelSmall?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.6),
            )),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Waitlist tab
// ─────────────────────────────────────────────────────────────────────────────
class _WaitlistTab extends StatelessWidget {
  final List<Map<String, dynamic>>? waitlist;
  final Future<void> Function() onRefresh;
  const _WaitlistTab({required this.waitlist, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (waitlist == null) {
      return const Center(
          child: CircularProgressIndicator(color: KittyColors.coral));
    }
    if (waitlist!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
          child: Text(
            'no waiting users or pending invites — every signed-up user is settled in a pod',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.55)),
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: KittyColors.coral,
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
        itemCount: waitlist!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _WaitlistRow(user: waitlist![i]),
      ),
    );
  }
}

class _WaitlistRow extends StatelessWidget {
  final Map<String, dynamic> user;
  const _WaitlistRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = user['display_name'] as String? ?? user['bunq_label'] as String? ?? '?';
    final trust = user['trust_score'] ?? 50;
    final goal = user['goal'] as String? ?? '';
    final since = _formatWhen(user['waitlist_since'] as String? ?? '');
    final prefs = (user['match_preferences'] as Map?) ?? {};
    final amount = (prefs['contribution_amount_cents'] ?? 0) as int;
    final cycles = prefs['cycle_count'] ?? 0;
    final urgency = prefs['urgency'] as String? ?? '';
    final candidates = (user['candidate_circles'] as List?) ?? const [];
    final state = user['state'] as String? ?? 'waiting';
    final pending = user['pending_invite'] as Map<String, dynamic>?;
    final isPending = state == 'invited_pending' && pending != null;
    final pendingGroup = (pending?['group'] as Map<String, dynamic>?) ?? const {};
    final pendingGroupName = pendingGroup['name'] as String? ?? '';
    final pendingDeadline = _formatWhen(pendingGroup['accept_deadline'] as String? ?? '');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.all(KittyRadius.l),
        boxShadow: KittyShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                    Text(name,
                        style: t.titleMedium?.copyWith(
                          color: KittyColors.bowl,
                          fontWeight: FontWeight.w700,
                        )),
                    if (isPending)
                      Text(
                        pendingDeadline.isEmpty
                            ? 'invited — awaiting accept'
                            : 'invited — accept by $pendingDeadline',
                        style: t.labelSmall?.copyWith(
                          color: KittyColors.coral,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else if (since.isNotEmpty)
                      Text('waiting since $since',
                          style: t.labelSmall?.copyWith(
                            color: KittyColors.dusk.withValues(alpha: 0.55),
                          )),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: KittyColors.coral.withValues(alpha: 0.13),
                  borderRadius: const BorderRadius.all(KittyRadius.full),
                ),
                child: Text('trust $trust',
                    style: t.labelSmall?.copyWith(
                      color: KittyColors.coral,
                      fontWeight: FontWeight.w700,
                    )),
              ),
            ],
          ),
          if (goal.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(goal,
                style: t.bodySmall?.copyWith(
                  color: KittyColors.dusk,
                  fontStyle: FontStyle.italic,
                )),
          ],
          if (amount > 0 || cycles != 0 || urgency.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (amount > 0)
                  _Chip(label: '€${(amount / 100).toStringAsFixed(0)}/mo'),
                if (cycles != 0) _Chip(label: '$cycles cycles'),
                if (urgency.isNotEmpty)
                  _Chip(label: urgency, color: KittyColors.coral),
              ],
            ),
          ],
          const SizedBox(height: 10),
          if (isPending)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: KittyColors.coral.withValues(alpha: 0.10),
                borderRadius: const BorderRadius.all(KittyRadius.m),
                border: Border.all(
                  color: KittyColors.coral.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mail_outline, size: 16, color: KittyColors.coral),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pendingGroupName.isEmpty
                          ? 'invite pending'
                          : 'invited to $pendingGroupName',
                      style: t.bodySmall?.copyWith(
                        color: KittyColors.bowl,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (candidates.isEmpty)
            Text('no matching pods right now',
                style: t.labelSmall?.copyWith(
                  color: KittyColors.dusk.withValues(alpha: 0.45),
                  fontStyle: FontStyle.italic,
                ))
          else ...[
            Text('CANDIDATE PODS',
                style: t.labelSmall?.copyWith(
                  color: KittyColors.dusk.withValues(alpha: 0.55),
                  letterSpacing: 1.0,
                )),
            const SizedBox(height: 6),
            ...candidates
                .cast<Map<String, dynamic>>()
                .map((c) => _CandidateCircleRow(circle: c)),
          ],
        ],
      ),
    );
  }
}

class _CandidateCircleRow extends StatelessWidget {
  final Map<String, dynamic> circle;
  const _CandidateCircleRow({required this.circle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fit = circle['fit_score'] ?? 0;
    final amount = (circle['contribution_amount_cents'] ?? 0) as int;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 28,
            decoration: BoxDecoration(
              color: fit >= 3
                  ? KittyColors.moss
                  : fit >= 1
                      ? KittyColors.coral
                      : KittyColors.dusk.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  circle['name'] as String? ?? '?',
                  style: t.bodySmall?.copyWith(
                    color: KittyColors.bowl,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '€${(amount / 100).toStringAsFixed(0)} × ${circle['cycle_count'] ?? '?'} · '
                  '${circle['theme'] ?? circle['status'] ?? ''}',
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          Text('fit $fit',
              style: t.labelSmall?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color? color;
  const _Chip({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? KittyColors.bowl;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: const BorderRadius.all(KittyRadius.full),
      ),
      child: Text(label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: c, fontWeight: FontWeight.w700)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Agents tab
// ─────────────────────────────────────────────────────────────────────────────
class _AgentsTab extends StatelessWidget {
  final Map<String, dynamic>? overview;
  final List<Map<String, dynamic>>? messages;
  final List<Map<String, dynamic>>? audit;
  final Future<void> Function() onRefresh;
  const _AgentsTab({
    required this.overview,
    required this.messages,
    required this.audit,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (messages == null || audit == null) {
      return const Center(child: CircularProgressIndicator(color: KittyColors.coral));
    }
    final t = Theme.of(context).textTheme;
    // Latest 12 agent tool-calls to surface what's happening right now.
    final latestAgentCalls = audit!
        .where((r) => (r['actor'] as String? ?? '').startsWith('agent:'))
        .take(12)
        .toList();
    return RefreshIndicator(
      color: KittyColors.coral,
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
        children: [
          _SectionLabel('latest tool calls'),
          if (latestAgentCalls.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('no agent activity yet',
                  style: t.bodySmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic,
                  )),
            )
          else
            ...latestAgentCalls.map((r) => _AuditRow(r, dense: true)),
          const SizedBox(height: 18),
          _SectionLabel('agent messages'),
          if (messages!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('no agent-authored messages yet',
                  style: t.bodySmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic,
                  )),
            )
          else
            ...messages!.map(_AgentMessageBubble.new),
        ],
      ),
    );
  }
}

class _AgentMessageBubble extends StatelessWidget {
  final Map<String, dynamic> msg;
  const _AgentMessageBubble(this.msg);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final agent = msg['agent_name'] as String? ?? 'agent';
    final content = (msg['text'] ?? msg['content']) as String? ?? '';
    final created = msg['created_at'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.45),
          borderRadius: const BorderRadius.all(KittyRadius.l),
          border: const Border(
            left: BorderSide(color: KittyColors.coral, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(agent,
                    style: t.labelSmall?.copyWith(
                      color: KittyColors.coral,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    )),
                const Spacer(),
                Text(_formatWhen(created),
                    style: t.labelSmall?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.45),
                    )),
              ],
            ),
            const SizedBox(height: 6),
            Text(content,
                style: t.bodySmall?.copyWith(color: KittyColors.dusk)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audit tab
// ─────────────────────────────────────────────────────────────────────────────
class _AuditTab extends StatelessWidget {
  final List<Map<String, dynamic>>? audit;
  final Future<void> Function() onRefresh;
  const _AuditTab({required this.audit, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (audit == null) {
      return const Center(child: CircularProgressIndicator(color: KittyColors.coral));
    }
    if (audit!.isEmpty) {
      return Center(
        child: Text('no audit rows yet',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.55))),
      );
    }
    return RefreshIndicator(
      color: KittyColors.coral,
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
        itemCount: audit!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, i) => _AuditRow(audit![i]),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool dense;
  const _AuditRow(this.row, {this.dense = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final actor = row['actor'] as String? ?? '';
    final isAgent = actor.startsWith('agent:');
    final actorLabel = isAgent ? actor.substring(6) : actor;
    final action = row['action'] as String? ?? '';
    final created = row['created_at'] as String? ?? '';
    final diff = row['diff'];
    final isFailure = action.endsWith('.error') ||
        action.endsWith('.failed') ||
        (diff is Map && diff['ok'] == false);
    return Container(
      padding: EdgeInsets.fromLTRB(12, dense ? 6 : 10, 12, dense ? 6 : 12),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.4),
        borderRadius: const BorderRadius.all(KittyRadius.m),
        border: Border(
          left: BorderSide(
            color: isFailure
                ? KittyColors.agentEmergency
                : (isAgent ? KittyColors.coral : KittyColors.bowl),
            width: 2.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (isAgent ? KittyColors.coral : KittyColors.bowl)
                      .withValues(alpha: 0.13),
                  borderRadius: const BorderRadius.all(KittyRadius.s),
                ),
                child: Text(isAgent ? 'agent' : 'user',
                    style: t.labelSmall?.copyWith(
                      color: isAgent ? KittyColors.coral : KittyColors.bowl,
                      fontWeight: FontWeight.w700,
                    )),
              ),
              const SizedBox(width: 8),
              Text(actorLabel,
                  style: t.labelLarge?.copyWith(
                    color: KittyColors.bowl,
                    fontWeight: FontWeight.w600,
                  )),
              if (isFailure) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: KittyColors.agentEmergency.withValues(alpha: 0.15),
                    borderRadius: const BorderRadius.all(KittyRadius.s),
                  ),
                  child: Text('failed',
                      style: t.labelSmall?.copyWith(
                        color: KittyColors.agentEmergency,
                        fontWeight: FontWeight.w700,
                      )),
                ),
              ],
              const Spacer(),
              Text(_formatWhen(created),
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.5),
                  )),
            ],
          ),
          const SizedBox(height: 4),
          Text(action,
              style: t.bodySmall?.copyWith(
                color: KittyColors.dusk,
                fontFamily: 'Menlo',
              )),
          if (!dense && diff != null && diff is Map && diff.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_summarizeDiff(diff),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                    fontFamily: 'Menlo',
                  )),
            ),
        ],
      ),
    );
  }

  String _summarizeDiff(Map d) {
    final parts = <String>[];
    d.forEach((k, v) {
      final s = v is Map || v is List ? '<${v.runtimeType}>' : '$v';
      parts.add('$k=$s');
    });
    return parts.join('  ');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Events tab
// ─────────────────────────────────────────────────────────────────────────────
class _EventsTab extends StatelessWidget {
  final List<Map<String, dynamic>>? events;
  final Future<void> Function() onRefresh;
  const _EventsTab({required this.events, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (events == null) {
      return const Center(child: CircularProgressIndicator(color: KittyColors.coral));
    }
    if (events!.isEmpty) {
      return Center(
        child: Text('no events yet — open a pod and watch them stream in',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: KittyColors.dusk.withValues(alpha: 0.55))),
      );
    }
    return RefreshIndicator(
      color: KittyColors.coral,
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
        itemCount: events!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, i) => _EventRow(events![i]),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final Map<String, dynamic> e;
  const _EventRow(this.e);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final type = e['type'] as String? ?? '';
    final actor = ((e['payload'] is Map ? e['payload']['actor'] : null) ??
            e['actor']) as String? ??
        '';
    final created = e['created_at'] as String? ?? '';
    final payload = e['payload'];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: KittyColors.soft.withValues(alpha: 0.4),
        borderRadius: const BorderRadius.all(KittyRadius.m),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(type,
                  style: t.titleSmall?.copyWith(
                    color: KittyColors.bowl,
                    fontWeight: FontWeight.w700,
                  )),
              const Spacer(),
              Text(_formatWhen(created),
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.5),
                  )),
            ],
          ),
          if (actor.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(actor,
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.55),
                  )),
            ),
          if (payload is Map && payload.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_summarize(payload),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(
                    color: KittyColors.dusk.withValues(alpha: 0.6),
                    fontFamily: 'Menlo',
                  )),
            ),
        ],
      ),
    );
  }

  String _summarize(Map p) {
    final parts = <String>[];
    p.forEach((k, v) {
      final s = v is Map || v is List ? '<${v.runtimeType}>' : '$v';
      parts.add('$k=$s');
    });
    return parts.join('  ');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
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
    if (now.difference(dt).inMinutes < 1) return 'just now';
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat.Hms().format(dt);
    }
    return DateFormat('MMM d  HH:mm').format(dt);
  } catch (_) {
    return '';
  }
}
