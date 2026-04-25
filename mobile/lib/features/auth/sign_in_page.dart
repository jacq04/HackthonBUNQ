import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;
import '../../core/theme/tokens.dart';
import '../../core/widgets/coral_button.dart';
import '../../services/api.dart';
import '../../services/supabase.dart';

/// Two-step sign-in:
///   1. method picker  ·  "sign in with bunq" (primary)  ·  "email me a code"
///   2. bunq picker    ·  list of sandbox identities w/ real name + IBAN
enum _Stage { method, bunqPick, emailEntry, emailCode }

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  _Stage _stage = _Stage.method;
  List<BunqUserCard>? _candidates;
  bool _busy = false;
  final _email = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _openBunqPicker() async {
    setState(() => _stage = _Stage.bunqPick);
    try {
      final list = await KittyApi().listBunqUsers();
      if (mounted) setState(() => _candidates = list);
    } catch (e) {
      if (mounted) {
        _toast("couldn't load bunq identities: $e");
        setState(() => _stage = _Stage.method);
      }
    }
  }

  Future<void> _signInWithBunq(BunqUserCard u) async {
    setState(() => _busy = true);
    try {
      final session = await KittyApi().signInWithBunq(u.label);
      final resp = await supabase.auth
          .verifyOTP(email: session.email, token: session.otp, type: OtpType.email);
      if (resp.session == null) throw 'no session returned';
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) _toast('sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendEmail() async {
    if (!_email.text.contains('@')) {
      _toast("that doesn't look like an email");
      return;
    }
    setState(() => _busy = true);
    try {
      await supabase.auth.signInWithOtp(
        email: _email.text.trim().toLowerCase(),
        emailRedirectTo: 'kitty://auth',
      );
      if (mounted) setState(() => _stage = _Stage.emailCode);
    } catch (e) {
      if (mounted) _toast("couldn't send: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyEmail() async {
    setState(() => _busy = true);
    try {
      await supabase.auth.verifyOTP(
        email: _email.text.trim().toLowerCase(),
        token: _code.text.replaceAll(RegExp(r'\D'), ''),
        type: OtpType.email,
      );
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) _toast("didn't work: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: KittyDurations.medium,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero)
                  .animate(anim),
              child: child,
            ),
          ),
          child: _buildStage(),
        ),
      ),
    );
  }

  Widget _buildStage() {
    switch (_stage) {
      case _Stage.method:
        return _MethodStage(
          key: const ValueKey('method'),
          onBunq: _openBunqPicker,
          onEmail: () => setState(() => _stage = _Stage.emailEntry),
        );
      case _Stage.bunqPick:
        return _BunqPickStage(
          key: const ValueKey('pick'),
          candidates: _candidates,
          busy: _busy,
          onPick: _signInWithBunq,
          onBack: () => setState(() => _stage = _Stage.method),
        );
      case _Stage.emailEntry:
        return _EmailStage(
          key: const ValueKey('email'),
          controller: _email,
          busy: _busy,
          onSend: _sendEmail,
          onBack: () => setState(() => _stage = _Stage.method),
        );
      case _Stage.emailCode:
        return _CodeStage(
          key: const ValueKey('code'),
          email: _email.text,
          controller: _code,
          busy: _busy,
          onVerify: _verifyEmail,
          onBack: () => setState(() => _stage = _Stage.emailEntry),
        );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Stage widgets
// ─────────────────────────────────────────────────────────────────────────
class _MethodStage extends StatelessWidget {
  final VoidCallback onBunq;
  final VoidCallback onEmail;
  const _MethodStage({super.key, required this.onBunq, required this.onEmail});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Hero(),
          const Spacer(),
          CoralButton(
            label: 'sign in with bunq',
            hero: true,
            onPressed: onBunq,
            leading: const _BeeIcon(),
          ).animate().fadeIn(duration: 420.ms, delay: 220.ms).slideY(begin: 0.4),
          const SizedBox(height: 12),
          CoralButton(
            label: 'email me a code',
            color: KittyColors.soft,
            foreground: KittyColors.dusk,
            onPressed: onEmail,
          ).animate().fadeIn(duration: 420.ms, delay: 320.ms).slideY(begin: 0.4),
          const SizedBox(height: 36),
          Text(
            "Sandbox demo — bunq sign-in uses pre-minted test accounts.",
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.5)),
          ).animate().fadeIn(duration: 420.ms, delay: 480.ms),
        ],
      ),
    );
  }
}

class _BunqPickStage extends StatelessWidget {
  final List<BunqUserCard>? candidates;
  final bool busy;
  final void Function(BunqUserCard) onPick;
  final VoidCallback onBack;
  const _BunqPickStage({
    super.key,
    required this.candidates,
    required this.busy,
    required this.onPick,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('pick a sandbox identity',
              style: t.headlineMedium?.copyWith(color: KittyColors.bowl)),
          const SizedBox(height: 8),
          Text(
            'Each identity is a bunq user with a real IBAN. You act as them for the rest of the demo.',
            style: t.bodyMedium?.copyWith(color: KittyColors.dusk.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: candidates == null
                ? const Center(
                    child: CircularProgressIndicator(color: KittyColors.coral),
                  )
                : ListView.separated(
                    itemCount: candidates!.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final u = candidates![i];
                      return _IdentityTile(user: u, busy: busy, onTap: () => onPick(u))
                          .animate()
                          .fadeIn(duration: 380.ms, delay: (80 * i).ms)
                          .slideY(begin: 0.2, curve: Curves.easeOutCubic);
                    },
                  ),
          ),
          Center(
            child: TextButton(onPressed: busy ? null : onBack, child: const Text('back')),
          ),
        ],
      ),
    );
  }
}

class _IdentityTile extends StatelessWidget {
  final BunqUserCard user;
  final bool busy;
  final VoidCallback onTap;
  const _IdentityTile({required this.user, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: const BorderRadius.all(KittyRadius.l),
      onTap: busy ? null : onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: KittyColors.soft.withValues(alpha: 0.7),
          borderRadius: const BorderRadius.all(KittyRadius.l),
        ),
        child: Row(
          children: [
            _Avatar(name: user.displayName),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.displayName,
                      style: t.titleMedium?.copyWith(color: KittyColors.dusk)),
                  const SizedBox(height: 2),
                  Text(
                    user.primaryIban ?? 'bunq #${user.bunqUserId ?? ""}',
                    style: t.bodySmall?.copyWith(
                      color: KittyColors.dusk.withValues(alpha: 0.55),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded,
                size: 14, color: KittyColors.dusk.withValues(alpha: 0.35)),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: KittyColors.bowl,
        shape: BoxShape.circle,
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: KittyColors.cream,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _EmailStage extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onBack;
  const _EmailStage({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSend,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Hero(),
          const SizedBox(height: 48),
          Text('email', style: t.labelMedium?.copyWith(color: KittyColors.dusk)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofocus: true,
            enableSuggestions: false,
            decoration: const InputDecoration(hintText: 'you@example.com'),
            style: t.bodyLarge,
          ),
          const SizedBox(height: 24),
          CoralButton(label: 'send code', loading: busy, onPressed: busy ? null : onSend),
          const SizedBox(height: 12),
          Center(child: TextButton(onPressed: busy ? null : onBack, child: const Text('back'))),
        ],
      ),
    );
  }
}

class _CodeStage extends StatelessWidget {
  final String email;
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onVerify;
  final VoidCallback onBack;
  const _CodeStage({
    super.key,
    required this.email,
    required this.controller,
    required this.busy,
    required this.onVerify,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Hero(),
          const SizedBox(height: 40),
          Text('we sent a 6-digit code to',
              style: t.bodyLarge?.copyWith(color: KittyColors.dusk)),
          Text(email, style: t.titleMedium),
          const SizedBox(height: 24),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(hintText: '• • • • • •', counterText: ''),
            style: t.displaySmall?.copyWith(letterSpacing: 14),
          ),
          CoralButton(
            label: 'verify',
            loading: busy,
            onPressed: busy || controller.text.length != 6 ? null : onVerify,
          ),
          const SizedBox(height: 12),
          Center(child: TextButton(onPressed: busy ? null : onBack, child: const Text('different email'))),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Kitty',
            style: t.displayLarge?.copyWith(color: KittyColors.bowl))
            .animate()
            .fadeIn(duration: 500.ms)
            .slideX(begin: -0.05, curve: Curves.easeOutCubic),
        const SizedBox(height: 8),
        Text(
          "Rotating savings,\nwith a pot that can't lie.",
          style: t.bodyLarge?.copyWith(
            color: KittyColors.dusk.withValues(alpha: 0.78),
            height: 1.4,
          ),
        ).animate().fadeIn(delay: 180.ms, duration: 500.ms).slideX(begin: -0.05),
      ],
    );
  }
}

class _BeeIcon extends StatelessWidget {
  const _BeeIcon();
  @override
  Widget build(BuildContext context) {
    return const Text('🐝', style: TextStyle(fontSize: 18));
  }
}
