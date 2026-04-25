/// Runtime configuration. All values come from --dart-define at launch so
/// developers can point at different envs without hard-coding secrets.
///
///   flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000 \
///               --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
///               --dart-define=SUPABASE_ANON_KEY=sb_publishable_...
class Env {
  const Env._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://127.0.0.1:54321',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
  );
}
