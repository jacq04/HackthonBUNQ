import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/pod_wordmark.dart';
import '../../services/api.dart';
import '../../services/supabase.dart';
import 'account_card.dart';
import 'transaction_tile.dart';

/// pod — the landing page. Pod is an ambigram wordmark (reads the same
/// rotated 180°) shown at the top. Account card carousel, then a "this week"
/// transaction list, then a compact entry point to Circles.
class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>>? _accounts;
  List<Map<String, dynamic>>? _txs;
  List<Map<String, dynamic>>? _circles;
  List<Map<String, dynamic>>? _invitations;
  int _currentCard = 0;
  final PageController _carousel = PageController(viewportFraction: 0.88);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = KittyApi();
      final results = await Future.wait([
        api.myProfile(),
        api.myAccounts(),
        api.myTransactions(days: 7),
        api.listGroups(),
        api.myInvitations(),
      ]);
      if (!mounted) return;
      final profile = results[0] as Map<String, dynamic>;
      // Admins land on the control room — they don't have a wallet view in
      // the product story; the platform's own bunq account is the collector.
      if (profile['is_admin'] == true) {
        if (mounted) context.go('/admin');
        return;
      }
      setState(() {
        _profile = profile;
        _accounts = List<Map<String, dynamic>>.from(results[1] as List);
        _txs = List<Map<String, dynamic>>.from(results[2] as List);
        _circles = List<Map<String, dynamic>>.from(results[3] as List);
        _invitations = List<Map<String, dynamic>>.from(results[4] as List);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('load failed: $e')));
      }
    }
  }

  /// Try to self-promote to admin. Succeeds when no admin exists yet
  /// (first-caller bootstrap); otherwise the backend returns 409 and we tell
  /// the user to ask an existing admin to grant them.
  Future<void> _claimAdmin() async {
    try {
      await KittyApi().adminBootstrap();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('admin granted — opening control room')),
      );
      await _load();
      if (mounted) context.push('/admin');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('not allowed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _carousel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = (_profile?['display_name'] as String?) ?? '';
    final firstName = name.split(' ').first;

    return Scaffold(
      body: RefreshIndicator(
        color: KittyColors.coral,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const PodWordmark(size: 52),
                    const Spacer(),
                    if (_profile?['is_admin'] == true)
                      IconButton(
                        tooltip: 'control room',
                        icon: const Icon(Icons.dashboard_rounded),
                        onPressed: () => context.push('/admin'),
                      )
                    else
                      IconButton(
                        tooltip: 'claim admin',
                        icon: const Icon(Icons.admin_panel_settings_outlined),
                        onPressed: _claimAdmin,
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
            ),
            // The pod. logo above already shows "CHIT TOGETHER" — skip the
            // redundant tagline and just greet the user.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 24, 22),
              child: Text(
                firstName.isEmpty ? 'welcome back' : 'hi, $firstName',
                style: t.bodyLarge?.copyWith(
                  color: KittyColors.dusk.withValues(alpha: 0.6),
                ),
              ),
            ),

            if (_profile?['waitlist_status'] == 'waiting')
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: _WaitlistBanner(profile: _profile!),
              ),

            if ((_invitations?.isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: _InvitationsBanner(invitations: _invitations!),
              ),

            // Account card carousel
            SizedBox(
              height: 210,
              child: _accounts == null
                  ? const Center(child: CircularProgressIndicator(color: KittyColors.coral))
                  : _accounts!.isEmpty
                      ? _EmptyAccounts()
                      : PageView.builder(
                          controller: _carousel,
                          onPageChanged: (i) => setState(() => _currentCard = i),
                          itemCount: _accounts!.length,
                          itemBuilder: (_, i) {
                            final a = _accounts![i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: AccountCard(
                                description:
                                    a['description'] as String? ?? 'bunq account',
                                iban: a['iban'] as String?,
                                balanceCents: a['balance_cents'] as int? ?? 0,
                                currency: a['currency'] as String? ?? 'EUR',
                                paletteIndex: a['palette_index'] as int? ?? i,
                              ),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 14),
            if ((_accounts?.length ?? 0) > 1)
              _CarouselDots(
                count: _accounts!.length,
                active: _currentCard,
              ).animate().fadeIn(),

            const SizedBox(height: 26),

            // This-week transactions
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'this week',
                    style: t.headlineSmall?.copyWith(color: KittyColors.bowl),
                  ),
                  Text(
                    '${_txs?.length ?? 0} transactions',
                    style: t.bodySmall?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _TransactionList(txs: _txs),

            const SizedBox(height: 32),

            // Circles entry — keeps the Kitty flow one tap away
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _CirclesCard(circles: _circles),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
/// "You're on the waitlist" — surfaces top candidate circles the Matchmaker
/// could place this user into, so the wait doesn't feel like a void.
class _WaitlistBanner extends StatelessWidget {
  final Map<String, dynamic> profile;
  const _WaitlistBanner({required this.profile});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final candidates =
        (profile['candidate_circles'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            KittyColors.bowl,
            KittyColors.ember,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.all(KittyRadius.l),
        boxShadow: KittyShadows.lift,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🕰️', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "you're on the waitlist",
                  style: t.titleMedium?.copyWith(
                    color: KittyColors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            candidates.isEmpty
                ? 'Matchmaker is searching — no perfect fit right now, hold tight.'
                : 'Matchmaker is matching you with these pods:',
            style: t.bodySmall?.copyWith(
              color: KittyColors.ink.withValues(alpha: 0.85),
            ),
          ),
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...candidates.map((c) {
              final amt = (c['contribution_amount_cents'] ?? 0) as int;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: KittyColors.ink,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${c['name']} · €${(amt / 100).toStringAsFixed(0)} × ${c['cycle_count']} '
                        '${c['theme'] != null ? '· ${c['theme']}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(
                          color: KittyColors.ink.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

/// Pending pod invitations the user hasn't accepted/declined yet. Tapping
/// any one routes to the accept page; until they decide, the pod is NOT in
/// the "your pods" list — so an invited-but-not-accepted user won't see a
/// pod on the carousel that they don't actually belong to.
class _InvitationsBanner extends StatelessWidget {
  final List<Map<String, dynamic>> invitations;
  const _InvitationsBanner({required this.invitations});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final n = invitations.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 16),
      decoration: BoxDecoration(
        color: KittyColors.soft,
        borderRadius: const BorderRadius.all(KittyRadius.l),
        border: Border.all(color: KittyColors.coral.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('✉️', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  n == 1
                      ? 'you have a pod invitation'
                      : 'you have $n pod invitations',
                  style: t.titleMedium?.copyWith(
                    color: KittyColors.cream,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...invitations.map((inv) => _InvitationRow(inv: inv)),
        ],
      ),
    );
  }
}

class _InvitationRow extends StatelessWidget {
  final Map<String, dynamic> inv;
  const _InvitationRow({required this.inv});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = inv['name'] as String? ?? 'pod';
    final amt = (inv['contribution_amount_cents'] ?? 0) as int;
    final cycles = inv['cycle_count'] ?? 0;
    final theme = inv['theme'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: const BorderRadius.all(KittyRadius.m),
        onTap: () => context.push('/group/${inv['id']}/accept'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: t.titleSmall?.copyWith(
                          color: KittyColors.cream,
                          fontWeight: FontWeight.w700,
                        )),
                    Text(
                      '€${(amt / 100).toStringAsFixed(0)} × $cycles cycles'
                      '${theme != null ? '  ·  $theme' : ''}',
                      style: t.bodySmall?.copyWith(
                        color: KittyColors.cream.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: KittyColors.coral,
                  borderRadius: const BorderRadius.all(KittyRadius.full),
                ),
                child: Text('review',
                    style: t.labelSmall?.copyWith(
                      color: KittyColors.ink,
                      fontWeight: FontWeight.w800,
                    )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyAccounts extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.5),
          borderRadius: const BorderRadius.all(KittyRadius.xl),
        ),
        child: Text(
          "No bunq accounts yet — sandbox may still be booting.",
          style: t.bodyMedium?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

class _CarouselDots extends StatelessWidget {
  final int count;
  final int active;
  const _CarouselDots({required this.count, required this.active});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final selected = i == active;
        return AnimatedContainer(
          duration: KittyDurations.short,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: selected ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: selected
                ? KittyColors.coral
                : KittyColors.dusk.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

class _TransactionList extends StatelessWidget {
  final List<Map<String, dynamic>>? txs;
  const _TransactionList({required this.txs});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (txs == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: KittyColors.coral)),
      );
    }
    if (txs!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: KittyColors.soft.withValues(alpha: 0.4),
            borderRadius: const BorderRadius.all(KittyRadius.xl),
          ),
          child: Text(
            "quiet week — no payments since last Monday",
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(
              color: KittyColors.dusk.withValues(alpha: 0.55),
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.32),
          borderRadius: const BorderRadius.all(KittyRadius.xl),
        ),
        child: Column(
          children: [
            for (int i = 0; i < txs!.length; i++)
              Column(
                children: [
                  TransactionTile(tx: txs![i])
                      .animate()
                      .fadeIn(duration: 320.ms, delay: (30 * i).ms)
                      .slideY(begin: 0.08),
                  if (i < txs!.length - 1)
                    Divider(
                      height: 1,
                      color: KittyColors.dusk.withValues(alpha: 0.06),
                      indent: 68,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CirclesCard extends StatelessWidget {
  final List<Map<String, dynamic>>? circles;
  const _CirclesCard({required this.circles});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final count = circles?.length ?? 0;
    final first = (circles?.isNotEmpty ?? false) ? circles!.first : null;
    return InkWell(
      borderRadius: const BorderRadius.all(KittyRadius.xl),
      onTap: () => context.push('/circles'),
      child: Ink(
        decoration: BoxDecoration(
          color: KittyColors.soft,
          borderRadius: const BorderRadius.all(KittyRadius.xl),
          border: Border.all(color: KittyColors.cream.withValues(alpha: 0.05)),
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: KittyColors.coral,
                shape: BoxShape.circle,
              ),
              child: const Text('🫕', style: TextStyle(fontSize: 26)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'your pods',
                    style: t.titleMedium?.copyWith(
                      color: KittyColors.cream,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    count == 0
                        ? 'no pods yet — find one'
                        : count == 1
                            ? ((first?['name'] as String?) ?? '1 pod')
                            : '$count pods',
                    style: t.bodySmall?.copyWith(
                      color: KittyColors.cream.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded,
                color: KittyColors.cream.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}
