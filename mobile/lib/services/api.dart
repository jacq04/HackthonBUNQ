import 'package:dio/dio.dart';
import 'env.dart';
import 'supabase.dart';

/// Typed client for the Kitty FastAPI backend. Injects the current Supabase
/// JWT on every request automatically; if no session exists, it still sends
/// (some routes are public).
class KittyApi {
  KittyApi._internal()
      : _dio = Dio(BaseOptions(
          baseUrl: Env.apiBaseUrl,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        )) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (opts, h) async {
      final token = supabase.auth.currentSession?.accessToken;
      if (token != null) {
        opts.headers['Authorization'] = 'Bearer $token';
      }
      h.next(opts);
    }));
  }

  static final KittyApi _i = KittyApi._internal();
  factory KittyApi() => _i;

  final Dio _dio;

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _dio.get(path);
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    final r = await _dio.get(path);
    return (r.data as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> _post(String path, Object body) async {
    final r = await _dio.post(path, data: body);
    return Map<String, dynamic>.from(r.data as Map);
  }

  // ─── Auth ────────────────────────────────────────────────────────────
  Future<List<BunqUserCard>> listBunqUsers() async {
    final rows = await _getList('/auth/bunq/users');
    return rows.map(BunqUserCard.fromJson).toList();
  }

  Future<({String email, String otp})> signInWithBunq(String label) async {
    final r = await _post('/auth/bunq', {'label': label});
    return (email: r['email'] as String, otp: r['otp'] as String);
  }

  // ─── Groups ──────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> listGroups() => _getList('/groups');
  Future<Map<String, dynamic>> getGroup(String id) => _get('/groups/$id');

  // ─── Matchmaker ──────────────────────────────────────────────────────
  Future<MatchResult> findCircle({
    required int contributionAmountCents,
    required int cycleCount,
    required String goal,
    String urgency = 'medium',
    String? culturalHint,
  }) async {
    final r = await _post('/matchmaker/find-circle', {
      'contribution_amount_cents': contributionAmountCents,
      'cycle_count': cycleCount,
      'goal': goal,
      'urgency': urgency,
      if (culturalHint != null && culturalHint.isNotEmpty)
        'cultural_hint': culturalHint,
    });
    return MatchResult.fromJson(r);
  }
}

class BunqUserCard {
  final String label;
  final String displayName;
  final int? bunqUserId;
  final String? primaryIban;
  final String? cultureHint;

  const BunqUserCard({
    required this.label,
    required this.displayName,
    this.bunqUserId,
    this.primaryIban,
    this.cultureHint,
  });

  factory BunqUserCard.fromJson(Map<String, dynamic> j) => BunqUserCard(
        label: j['label'] as String,
        displayName: j['display_name'] as String,
        bunqUserId: j['bunq_user_id'] as int?,
        primaryIban: j['primary_iban'] as String?,
        cultureHint: j['culture_hint'] as String?,
      );
}

class MatchResult {
  final String action; // joined | formed | waitlisted | none
  final String? groupId;
  final String? groupName;
  final int? payoutCycle;
  final int trustScore;
  final String rationale;

  const MatchResult({
    required this.action,
    this.groupId,
    this.groupName,
    this.payoutCycle,
    required this.trustScore,
    required this.rationale,
  });

  factory MatchResult.fromJson(Map<String, dynamic> j) => MatchResult(
        action: j['action'] as String,
        groupId: j['group_id'] as String?,
        groupName: j['group_name'] as String?,
        payoutCycle: j['payout_cycle'] as int?,
        trustScore: j['trust_score'] as int,
        rationale: j['rationale'] as String,
      );
}
