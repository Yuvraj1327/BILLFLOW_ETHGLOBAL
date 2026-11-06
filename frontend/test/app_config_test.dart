import 'dart:convert';
import 'dart:io';

import 'package:billflow/core/config/app_config.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

String jwt(String role) => 'x.${base64Url.encode(utf8.encode(jsonEncode({'role': role}))).replaceAll('=', '')}.y';
void load(String s) => dotenv.loadFromString(envString: s.isEmpty ? '# empty' : s);
String base(String extra) => 'API_BASE_URL=http://localhost:8000/api/v1\nSUPABASE_URL=https://p.supabase.co\nSUPABASE_ANON_KEY=${jwt('anon')}\n$extra';

void main() {
  test('reads values, ignores comments, applies defaults', () {
    load(base('# note\nCHAIN_ID=1874\nCHECKOUT_BASE_URL=http://localhost:8080   # inline comment\n'));
    expect(AppConfig.isConfigured, isTrue);
    expect(AppConfig.supabaseUrl, 'https://p.supabase.co');
    expect(AppConfig.chainId, 1874);
    expect(AppConfig.checkoutBaseUrl, 'http://localhost:8080');
    expect(AppConfig.rpcUrl, startsWith('https://rpc.'));
  });
  test('bare API host gets /api/v1', () {
    load('API_BASE_URL=http://localhost:8000/\nSUPABASE_URL=https://p.supabase.co\nSUPABASE_ANON_KEY=${jwt('anon')}');
    expect(AppConfig.apiBaseUrl, 'http://localhost:8000/api/v1');
  });
  test('API_BASE_URL without a scheme gets one (https, or http for localhost)', () {
    String api(String v) {
      load('API_BASE_URL=$v\nSUPABASE_URL=https://p.supabase.co\nSUPABASE_ANON_KEY=${jwt('anon')}');
      return AppConfig.apiBaseUrl;
    }
    expect(api('my-app.up.railway.app/api/v1'), 'https://my-app.up.railway.app/api/v1');
    expect(api('my-app.up.railway.app'), 'https://my-app.up.railway.app/api/v1');
    expect(api('localhost:8000/api/v1'), 'http://localhost:8000/api/v1');
    expect(api('https://x.io/api/v1/'), 'https://x.io/api/v1');
  });
  test('missing values → not configured', () {
    load('');
    expect(AppConfig.isConfigured, isFalse);
    expect(AppConfig.problem, contains('frontend/.env'));
  });
  test('secrets in the client .env are rejected', () {
    for (final k in ['SUPABASE_SERVICE_ROLE_KEY', 'ANTHROPIC_API_KEY', 'QUOTE_SIGNER_PRIVATE_KEY', 'DATABASE_URL']) {
      load(base('$k=abc\n'));
      expect(AppConfig.isConfigured, isFalse, reason: k);
    }
    load('API_BASE_URL=http://localhost:8000\nSUPABASE_URL=https://p.supabase.co\nSUPABASE_ANON_KEY=${jwt('service_role')}');
    expect(AppConfig.problem, contains('service-role'));
  });
  test('the real frontend/.env is valid, public-only and bundled as an asset', () {
    load(File('.env').readAsStringSync());
    expect(AppConfig.problem, isNull);
    expect(AppConfig.apiBaseUrl, endsWith('/api/v1'));
    expect(File('pubspec.yaml').readAsStringSync(), contains('- .env'));
  });
}
