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

  Future<({String email, String otp})> signInByPhone(String phone) async {
    final r = await _post('/auth/bunq/by-phone', {'phone': phone});
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

  // ─── pod landing (bunq wallet view) ──────────────────────────────
  Future<Map<String, dynamic>> myProfile() => _get('/me/profile');

  Future<List<Map<String, dynamic>>> myAccounts() => _getList('/me/accounts');
  Future<List<Map<String, dynamic>>> myInvitations() => _getList('/me/invitations');

  Future<List<Map<String, dynamic>>> myTransactions({int? accountId, int days = 7}) async {
    final q = StringBuffer('/me/transactions?days=$days');
    if (accountId != null) q.write('&account_id=$accountId');
    return _getList(q.toString());
  }

  // ─── Circle Lifecycle v2 ────────────────────────────────────────────
  Future<RespondResult> respondToInvite(
    String groupId, {
    required String decision,     // 'accept' | 'decline'
    int? debitDay,
    int? monthlyCapCents,
    int termsVersion = 1,
  }) async {
    final r = await _post('/groups/$groupId/invites/respond', {
      'decision': decision,
      if (debitDay != null) 'debit_day': debitDay,
      if (monthlyCapCents != null) 'monthly_cap_cents': monthlyCapCents,
      'terms_version': termsVersion,
    });
    return RespondResult.fromJson(r);
  }

  Future<Map<String, dynamic>> startCircle(String groupId) =>
      _post('/groups/$groupId/start', {});

  Future<Map<String, dynamic>> placeBid(
    String groupId,
    int cycleMonth, {
    required String urgency,
    required String reason,
  }) =>
      _post('/groups/$groupId/cycles/$cycleMonth/bid', {
        'urgency': urgency,
        'reason': reason,
      });

  Future<Map<String, dynamic>> resolveCycle(String groupId, int cycleMonth) =>
      _post('/groups/$groupId/cycles/$cycleMonth/resolve', {});

  // ─── Admin dashboard ────────────────────────────────────────────────
  Future<Map<String, dynamic>> adminBootstrap() => _post('/admin/bootstrap', {});
  Future<Map<String, dynamic>> adminCreateCircle(Map<String, dynamic> body) =>
      _post('/admin/circles', body);
  Future<Map<String, dynamic>> adminUpdateCircle(
    String groupId,
    Map<String, dynamic> body,
  ) async {
    final r = await _dio.patch('/admin/circles/$groupId', data: body);
    return Map<String, dynamic>.from(r.data as Map);
  }
  Future<Map<String, dynamic>> adminDeleteCircle(String groupId) async {
    final r = await _dio.delete('/admin/circles/$groupId');
    return Map<String, dynamic>.from(r.data as Map);
  }
  Future<Map<String, dynamic>> adminGrant(String targetUserId) =>
      _post('/admin/grant?target_user_id=$targetUserId', {});
  Future<Map<String, dynamic>> adminRevoke(String targetUserId) =>
      _post('/admin/revoke?target_user_id=$targetUserId', {});
  Future<Map<String, dynamic>> adminOverview() => _get('/admin/overview');
  Future<List<Map<String, dynamic>>> adminGroups() => _getList('/admin/groups');
  Future<Map<String, dynamic>> adminGroup(String id) => _get('/admin/groups/$id');
  Future<List<Map<String, dynamic>>> adminAudit({int limit = 200, String? actorKind}) {
    final q = StringBuffer('/admin/audit?limit=$limit');
    if (actorKind != null) q.write('&actor_kind=$actorKind');
    return _getList(q.toString());
  }
  Future<List<Map<String, dynamic>>> adminAgentMessages({int limit = 200}) =>
      _getList('/admin/agent-messages?limit=$limit');
  Future<List<Map<String, dynamic>>> adminEvents({int limit = 200, String? typePrefix}) {
    final q = StringBuffer('/admin/events?limit=$limit');
    if (typePrefix != null) q.write('&type_prefix=$typePrefix');
    return _getList(q.toString());
  }
  Future<List<Map<String, dynamic>>> adminWaitlist() => _getList('/admin/waitlist');
  Future<List<Map<String, dynamic>>> adminCycles({String? groupId, int limit = 200}) {
    final q = StringBuffer('/admin/cycles?limit=$limit');
    if (groupId != null) q.write('&group_id=$groupId');
    return _getList(q.toString());
  }
}

class RespondResult {
  final String decision;
  final String memberStatus;
  final String groupStatus;
  final String? mandateId;
  final String? bunqMandateId;
  final int acceptedCount;
  final int targetCount;
  const RespondResult({
    required this.decision,
    required this.memberStatus,
    required this.groupStatus,
    this.mandateId,
    this.bunqMandateId,
    required this.acceptedCount,
    required this.targetCount,
  });
  factory RespondResult.fromJson(Map<String, dynamic> j) => RespondResult(
        decision: j['decision'] as String,
        memberStatus: j['member_status'] as String,
        groupStatus: j['group_status'] as String,
        mandateId: j['mandate_id'] as String?,
        bunqMandateId: j['bunq_mandate_id'] as String?,
        acceptedCount: j['accepted_count'] as int,
        targetCount: j['target_count'] as int,
      );
}

class BunqUserCard {
  final String label;
  final String displayName;
  final int? bunqUserId;
  final String? primaryIban;
  final String? phone;
  final String? cultureHint;

  const BunqUserCard({
    required this.label,
    required this.displayName,
    this.bunqUserId,
    this.primaryIban,
    this.phone,
    this.cultureHint,
  });

  factory BunqUserCard.fromJson(Map<String, dynamic> j) => BunqUserCard(
        label: j['label'] as String,
        displayName: j['display_name'] as String,
        bunqUserId: j['bunq_user_id'] as int?,
        primaryIban: j['primary_iban'] as String?,
        phone: j['phone'] as String?,
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
