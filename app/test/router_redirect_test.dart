import 'package:billflow/app/router.dart';
import 'package:billflow/shared/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Profile p(String role, {String? biz}) => Profile({'id': 'u', 'role': role, 'investor_verification': 'unverified', 'business_id': biz});
const loading = AsyncValue<Profile?>.loading();

String? r(String loc, AsyncValue<Profile?> a, {bool configured = true}) => computeRedirect(loc: loc, configured: configured, auth: a);

void main() {
  test('unconfigured build goes to the setup error screen', () {
    expect(r('/login', const AsyncData(null), configured: false), '/setup-error');
  });
  test('public checkout and receipts bypass auth', () {
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
    expect(r('/admin', AsyncData(p('admin'))), isNull);
  });
  test('merchant without a business is sent to onboarding', () {
    expect(r('/merchant', AsyncData(p('merchant'))), '/onboarding/business');
    expect(r('/onboarding/business', AsyncData(p('merchant'))), isNull);
    expect(r('/onboarding/business', AsyncData(p('merchant', biz: 'b'))), '/merchant');
  });
}
