import 'package:billflow/app/router.dart';
import 'package:billflow/shared/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Profile p(String role, {String? biz, String verif = 'verified'}) => Profile({'id': 'u', 'role': role, 'investor_verification': verif, 'business_id': biz});
const loading = AsyncValue<Profile?>.loading();

String? r(String loc, AsyncValue<Profile?> a, {bool configured = true}) => computeRedirect(loc: loc, configured: configured, auth: a);

void main() {
  test('unconfigured build goes to the setup error screen', () {
    expect(r('/login', const AsyncData(null), configured: false), '/setup-error');
  });
  test('public checkout and receipts bypass auth', () {
    expect(r('/pay', const AsyncData(null)), isNull);
    expect(r('/pay', loading), isNull);
    expect(r('/pay/abc', const AsyncData(null)), isNull);
    expect(r('/receipt/abc/0x1', loading), isNull);
  });
  test('loading → splash; anonymous → welcome', () {
    expect(r('/merchant', loading), '/splash');
    expect(r('/merchant', const AsyncData(null)), '/welcome');
    expect(r('/login', const AsyncData(null)), isNull);
  });
  test('signed-in users leave auth screens for their role home', () {
    expect(r('/login', AsyncData(p('merchant', biz: 'b'))), '/merchant');
    expect(r('/welcome', AsyncData(p('investor'))), '/investor');
    expect(r('/login', AsyncData(p('admin'))), '/admin');
    expect(r('/login', AsyncData(p('customer'))), '/customer');
  });
  test('role guards: a role cannot open another role area', () {
    expect(r('/admin', AsyncData(p('merchant', biz: 'b'))), '/merchant');
    expect(r('/admin/users', AsyncData(p('investor'))), '/investor');
    expect(r('/merchant/invoices', AsyncData(p('customer'))), '/customer');
    expect(r('/investor', AsyncData(p('admin'))), '/admin');
    expect(r('/investor/portfolio', AsyncData(p('merchant', biz: 'b'))), '/merchant');
    expect(r('/investor/verification', AsyncData(p('merchant', biz: 'b'))), '/merchant');
    expect(r('/onboarding/investor', AsyncData(p('admin'))), '/admin');
    expect(r('/admin', AsyncData(p('admin'))), isNull);
  });
  test('merchant without a business still lands on the dashboard (setup is optional)', () {
    expect(r('/merchant', AsyncData(p('merchant'))), isNull);
    expect(r('/login', AsyncData(p('merchant'))), '/merchant');
    expect(r('/onboarding/business', AsyncData(p('merchant'))), isNull);
    expect(r('/onboarding/business', AsyncData(p('investor'))), '/investor');
  });
  test('admin login is reachable anonymously; admins leave it', () {
    expect(r('/admin-login', const AsyncData(null)), isNull);
    expect(r('/admin-login', AsyncData(p('admin'))), '/admin');
    expect(r('/admin-login', AsyncData(p('merchant', biz: 'b'))), '/merchant');
  });
  test('investors go straight to the dashboard whatever their verification status', () {
    for (final v in ['unverified', 'pending', 'rejected', 'verified']) {
      final a = AsyncData(p('investor', verif: v));
      expect(r('/login', a), '/investor');
      expect(r('/investor', a), isNull);
      expect(r('/investor/portfolio', a), isNull);
      expect(r('/onboarding/investor', a), isNull); // optional
    }
    expect(r('/onboarding/investor', AsyncData(p('merchant', biz: 'b'))), '/merchant');
  });
}
