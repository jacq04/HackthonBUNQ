// pod. — voice tour bottom sheet.
//
// A modal bottom sheet that hosts the live voice conversation. Owns one
// PodVoice for its lifetime; tears it down on close. The orb is driven by
// the model audio level; transcript rows render from the service's running
// transcript + partials.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../services/voice.dart';

class VoiceSheet extends StatefulWidget {
  const VoiceSheet({super.key});

  /// Spawns the modal. Returns when the sheet closes.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const VoiceSheet(),
    );
  }

  @override
  State<VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<VoiceSheet> {
  late final PodVoice _voice;

  @override
  void initState() {
    super.initState();
    _voice = PodVoice();
    _voice.addListener(_onChange);
    // wire navigateTo tool → go_router push, so the model can drive the app
    _voice.onNavigate = (route) {
      if (!mounted) return;
      try {
        GoRouter.of(context).go(route);
      } catch (_) {
        // ignore — route may not exist
      }
    };
    _voice.start();
  }

  @override
  void dispose() {
    _voice.removeListener(_onChange);
    _voice.stop();
    _voice.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: KittyColors.creamDark,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(color: Color(0x22FFFFFF)),
          ),
        ),
        child: Column(
          children: [
            // grabber
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'live · gemini 2.5 live',
                          style: t.labelSmall?.copyWith(
                            color: Colors.white54,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "pod. voice tour",
                          style: t.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: KittyColors.dusk,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Colors.white70,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Color(0x22FFFFFF)),

            // orb + state
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                children: [
                  _Orb(state: _voice.state, level: _voice.level),
                  const SizedBox(height: 12),
                  Text(
                    _stateLabel(_voice.state),
                    style: t.labelMedium?.copyWith(
                      color: _stateColor(_voice.state),
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'ask "how does a pod work?" · "show me the wallet"',
                      textAlign: TextAlign.center,
                      style: t.bodySmall?.copyWith(
                        color: Colors.white54,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // transcript
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: KittyColors.soft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x14FFFFFF)),
                ),
                child: _buildTranscript(t, scrollController),
              ),
            ),

            // action row
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: _voice.muted ? 'unmute' : 'mute',
                        active: _voice.muted,
                        activeColor: KittyColors.amber,
                        onTap: _voice.toggleMute,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        label: 'end call',
                        filled: true,
                        fillColor: KittyColors.rust,
                        onTap: () => Navigator.pop(context),
                      ),
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

  Widget _buildTranscript(TextTheme t, ScrollController controller) {
    final rows = <TranscriptRow>[
      ..._voice.transcript,
      if (_voice.partialUser != null) _voice.partialUser!,
      if (_voice.partialAssistant != null) _voice.partialAssistant!,
    ];

    if (rows.isEmpty) {
      return Center(
        child: Text(
          'transcript will appear here.',
          style: t.bodySmall?.copyWith(
            color: Colors.white38,
            letterSpacing: 1.2,
          ),
        ),
      );
    }

    // auto-scroll to bottom on new content
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final max = controller.position.maxScrollExtent;
      controller.animateTo(
        max,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });

    return ListView.separated(
      controller: controller,
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _TranscriptRowView(row: rows[i]),
    );
  }

  String _stateLabel(VoiceState s) {
    switch (s) {
      case VoiceState.idle:
        return 'READY';
      case VoiceState.connecting:
        return 'CONNECTING…';
      case VoiceState.listening:
        return 'LISTENING';
      case VoiceState.speaking:
        return 'SPEAKING';
      case VoiceState.error:
        return "COULDN'T CONNECT";
    }
  }

  Color _stateColor(VoiceState s) {
    switch (s) {
      case VoiceState.listening:
        return KittyColors.moss;
      case VoiceState.speaking:
        return KittyColors.coral;
      case VoiceState.connecting:
        return KittyColors.amber;
      case VoiceState.error:
        return KittyColors.rust;
      case VoiceState.idle:
        return Colors.white54;
    }
  }
}

// ============================================================
// orb
// ============================================================

class _Orb extends StatelessWidget {
  const _Orb({required this.state, required this.level});
  final VoiceState state;
  final double level;

  @override
  Widget build(BuildContext context) {
    final base = state == VoiceState.error
        ? KittyColors.rust
        : state == VoiceState.connecting
            ? KittyColors.amber
            : KittyColors.coral;
    final scale = 1.0 + level * 0.18;
    final glow = 8.0 + level * 26.0;

    return AnimatedScale(
      duration: const Duration(milliseconds: 120),
      scale: scale,
      child: Container(
        width: 128,
        height: 128,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white12,
        ),
        alignment: Alignment.center,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                base.withValues(alpha: 0.95),
                base.withValues(alpha: 0.55),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: base.withValues(alpha: 0.45),
                blurRadius: glow,
                spreadRadius: glow * 0.25,
              )
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// row + button
// ============================================================

class _TranscriptRowView extends StatelessWidget {
  const _TranscriptRowView({required this.row});
  final TranscriptRow row;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final roleColor = switch (row.role) {
      'assistant' => KittyColors.coral,
      'user' => KittyColors.moss,
      _ => KittyColors.rust,
    };
    final roleText = switch (row.role) {
      'assistant' => 'pod.',
      'user' => 'you',
      _ => 'system',
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            roleText,
            style: t.labelSmall?.copyWith(
              color: roleColor,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            row.text + (row.partial ? ' ▍' : ''),
            style: t.bodyMedium?.copyWith(
              color: row.partial ? KittyColors.dusk.withValues(alpha: 0.78) : KittyColors.dusk,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.filled = false,
    this.fillColor,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final bool filled;
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final bg = filled
        ? (fillColor ?? KittyColors.coral)
        : (active ? (activeColor ?? KittyColors.amber) : Colors.transparent);
    final fg = filled || active ? KittyColors.cream : KittyColors.dusk;
    final border = filled || active
        ? (filled ? (fillColor ?? KittyColors.coral) : (activeColor ?? KittyColors.amber))
        : const Color(0x33FFFFFF);

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(color: border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          child: Center(
            child: Text(
              label,
              style: t.labelLarge?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
