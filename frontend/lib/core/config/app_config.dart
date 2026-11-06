import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Public client configuration, read from `frontend/.env` (a Flutter asset loaded by [AppConfig.load] in `main`).
/// The file ships inside the app, so it may only hold PUBLIC values: never a service-role key, Anthropic key or private key.
class AppConfig {
  static String _env(String key, [String fallback = '']) {
    if (!dotenv.isInitialized) return fallback;
    final v = (dotenv.env[key] ?? '').trim();
    return v.isEmpty ? fallback : v;
  }

  /// Loads `.env`. A missing file is not fatal: [isConfigured] turns false and the app shows the setup screen.
  static Future<void> load({String fileName = '.env'}) async {
    try {
      await dotenv.load(fileName: fileName);
    } catch (_) {
      dotenv.loadFromString(envString: '# empty'); // initialised but empty (an empty string throws)
    }
  }

  static String get _apiBaseRaw => _env('API_BASE_URL');

  /// Always ends in the API prefix: a bare host such as `http://localhost:8000` gets `/api/v1` appended
  /// (routes live under it, so a bare host made every call 404).
  static String get apiBaseUrl {
    var u = _apiBaseRaw.replaceAll(RegExp(r'/+$'), '');
    if (u.isEmpty) return '';
    // A value without a scheme (e.g. `my-app.up.railway.app/api/v1`) would be treated as a relative path and silently call
    // the web page's own origin. Add one: http for localhost / private hosts, https for everything else.
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(u)) {
      final local = RegExp(r'^(localhost|127\.0\.0\.1|10\.|192\.168\.|0\.0\.0\.0)').hasMatch(u);
      u = '${local ? 'http' : 'https'}://$u';
    }
    return (Uri.tryParse(u)?.path ?? '').isEmpty ? '$u/api/v1' : u;
  }

  static String get supabaseUrl => _env('SUPABASE_URL');
  static String get supabaseAnonKey => _env('SUPABASE_ANON_KEY');

  // Whitechain Sepolia (OP Stack L2). Defaults match the approved Step 1 docs; override in .env if Whitechain changes them.
  static int get chainId => int.tryParse(_env('CHAIN_ID')) ?? 1874;
  static String get rpcUrl => _env('RPC_URL', 'https://rpc.testnet.whitechain.io');
  static String get explorerUrl => _env('EXPLORER_URL', 'https://explorer.testnet.whitechain.io');
  static String get checkoutBaseUrl => _env('CHECKOUT_BASE_URL');

  static const chainName = 'Whitechain Sepolia';
  static const nativeSymbol = 'WBT';

  /// Keys that must never reach a client bundle.
  static const forbiddenKeys = ['SERVICE_ROLE', 'ANTHROPIC', 'PRIVATE_KEY', 'SECRET', 'DATABASE_URL'];

  /// Why the configuration is unusable, or null when it is fine. Rejects secrets: `.env` is bundled into the app.
  static String? get problem {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty || _apiBaseRaw.isEmpty) {
      return 'API_BASE_URL, SUPABASE_URL and SUPABASE_ANON_KEY must be set in frontend/.env.';
    }
    if (dotenv.isInitialized) {
      for (final k in dotenv.env.keys) {
        if (forbiddenKeys.any((f) => k.toUpperCase().contains(f))) {
          return 'frontend/.env contains "$k". Secrets must never be placed in the Flutter app; remove it.';
        }
      }
    }
    if (_jwtRole(supabaseAnonKey) == 'service_role') {
      return 'SUPABASE_ANON_KEY is a service-role key. Use the public anon key; the service-role key must stay on the server.';
    }
    return null;
  }

  static bool get isConfigured => problem == null;

  static String? _jwtRole(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final body = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      return body['role']?.toString();
    } catch (_) {
      return null;
    }
  }

  static String txUrl(String hash) => '${explorerUrl.replaceAll(RegExp(r'/+$'), '')}/tx/$hash';
  static String addressUrl(String a) => '${explorerUrl.replaceAll(RegExp(r'/+$'), '')}/address/$a';
}
