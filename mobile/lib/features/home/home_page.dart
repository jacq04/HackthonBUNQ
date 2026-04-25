import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../services/api.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>>? _groups;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final g = await KittyApi().listGroups();
      if (mounted) setState(() => _groups = g);
    } catch (e) {
      if (mounted) setState(() => _groups = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final groups = _groups;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    tooltip: 'back to wallet',
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/');
                      }
                    },
                  ),
                  const SizedBox(width: 4),
                  Text('your pods',
                      style: t.headlineLarge?.copyWith(color: KittyColors.bowl)),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: groups == null
                    ? const Center(child: CircularProgressIndicator(color: KittyColors.coral))
                    : groups.isEmpty
                        ? _EmptyState()
                        : RefreshIndicator(
                            color: KittyColors.coral,
                            onRefresh: _load,
                            child: ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: groups.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 14),
                              itemBuilder: (_, i) {
                                final g = groups[i];
                                return _GroupCard(group: g)
                                    .animate()
                                    .fadeIn(duration: 380.ms, delay: (80 * i).ms)
                                    .slideY(begin: 0.12);
                              },
                            ),
                          ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: CoralButton(
                          label: 'find a pod',
                          hero: true,
                          onPressed: () => context.push('/find-circle'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      CoralButton(
                        label: 'join by code',
                        color: KittyColors.bowl,
                        foreground: KittyColors.cream,
                        onPressed: () {/* TODO QR join */},
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final Map<String, dynamic> group;
  const _GroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final amount = (group['contribution_amount_cents'] ?? 0) / 100;
    final cycles = group['cycle_count'] ?? 0;
    final status = group['status'] ?? '';
    return InkWell(
      borderRadius: const BorderRadius.all(KittyRadius.xl),
      onTap: () => context.push('/group/${group['id']}'),
      child: Ink(
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.all(KittyRadius.xl),
          boxShadow: KittyShadows.card,
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: KittyColors.bowl,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: const Text('🫕', style: TextStyle(fontSize: 28)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(group['name'] ?? '',
                      style: t.headlineSmall?.copyWith(color: KittyColors.bowl)),
                  const SizedBox(height: 4),
                  Text(
                    '€${amount.toStringAsFixed(0)}  ·  $cycles cycles  ·  $status',
                    style: t.bodyMedium?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded,
                color: KittyColors.dusk.withValues(alpha: 0.35)),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🫕', style: TextStyle(fontSize: 60, color: KittyColors.bowl))
              .animate(onPlay: (c) => c.repeat())
              .shimmer(duration: 3.seconds, color: KittyColors.coral.withValues(alpha: 0.6)),
          const SizedBox(height: 18),
          Text('no pods yet',
              style: t.headlineSmall?.copyWith(color: KittyColors.bowl)),
          const SizedBox(height: 6),
          SizedBox(
            width: 260,
            child: Text(
              "Tell our Matchmaker what you're saving for — we'll match you to a pod that fits.",
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.6)),
            ),
          ),
        ],
      ).animate().fadeIn(duration: 600.ms),
    );
  }
}
