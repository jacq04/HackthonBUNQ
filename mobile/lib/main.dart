import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/theme.dart';
import 'features/auth/sign_in_page.dart';
import 'features/cycle/place_bid_page.dart';
import 'features/group/accept_invite_page.dart';
import 'features/group/group_detail_page.dart';
import 'features/admin/admin_page.dart';
import 'features/admin/admin_pod_detail_page.dart';
import 'features/home/home_page.dart';
import 'features/matchmaker/find_circle_page.dart';
import 'features/wallet/wallet_page.dart';
import 'services/supabase.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initSupabase();
  runApp(const ProviderScope(child: KittyApp()));
}

class KittyApp extends StatefulWidget {
  const KittyApp({super.key});

  @override
  State<KittyApp> createState() => _KittyAppState();
}

class _KittyAppState extends State<KittyApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = _buildRouter();
    supabase.auth.onAuthStateChange.listen((_) {
      if (mounted) _router.refresh();
    });
  }

  GoRouter _buildRouter() {
    return GoRouter(
      initialLocation: '/',
      refreshListenable: _AuthListenable(),
      redirect: (context, state) {
        final loggedIn = supabase.auth.currentSession != null;
        final onAuth = state.matchedLocation == '/sign-in';
        if (!loggedIn && !onAuth) return '/sign-in';
        if (loggedIn && onAuth) return '/';
        return null;
      },
      routes: [
        GoRoute(path: '/sign-in', builder: (_, __) => const SignInPage()),
        GoRoute(path: '/', builder: (_, __) => const WalletPage()),
        GoRoute(path: '/circles', builder: (_, __) => const HomePage()),
        GoRoute(path: '/admin', builder: (_, __) => const AdminPage()),
        GoRoute(
          path: '/admin/pods/:id',
          builder: (_, s) =>
              AdminPodDetailPage(groupId: s.pathParameters['id']!),
        ),
        GoRoute(path: '/find-circle', builder: (_, __) => const FindCirclePage()),
        GoRoute(
          path: '/group/:id',
          builder: (_, s) => GroupDetailPage(groupId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/group/:id/accept',
          builder: (_, s) =>
              AcceptInvitePage(groupId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/group/:id/cycle/:cycle/bid',
          builder: (_, s) => PlaceBidPage(
            groupId: s.pathParameters['id']!,
            cycleMonth: int.parse(s.pathParameters['cycle']!),
            potCents:
                int.tryParse(s.uri.queryParameters['pot'] ?? '0') ?? 0,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'pod',
      debugShowCheckedModeBanner: false,
      // Locked to dark — the bunq-kit aesthetic (Marvilo PDF page 4) is a
      // black-canvas product, and the brand pops sharper without a light
      // alternative. Light theme retained as a fallback for accessibility
      // overrides at the OS level if anyone forces it.
      theme: kittyTheme(brightness: Brightness.dark),
      darkTheme: kittyTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
    );
  }
}

/// Fires `notifyListeners` whenever the Supabase auth state changes so
/// go_router re-evaluates its `redirect`.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable() {
    supabase.auth.onAuthStateChange.listen((_) => notifyListeners());
  }
}
