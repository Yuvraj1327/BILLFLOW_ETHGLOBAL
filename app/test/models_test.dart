import 'package:billflow/shared/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> invoiceJson({String status = 'PENDING', String paidBase = '0', String? financing, String due = '2999-01-01'}) => {
      'id': 'i1', 'customer_id': 'c1', 'customer_name': 'Globex', 'invoice_number': 'INV-1', 'description': 'x',
      'amount': '100', 'amount_base': '100000000', 'token_decimals': 6, 'currency': 'USDT',
      'issue_date': '2026-11-05', 'due_date': due, 'status': status, 'paid_amount': '0', 'paid_amount_base': paidBase,
      'review_status': 'unverified', 'financing_status': financing,
    };

void main() {
  test('Paged parses the backend envelope', () {
    final p = Paged.from({'items': [invoiceJson()], 'page': 1, 'page_size': 20, 'total': 41}, Invoice.new);
    expect(p.items.single.number, 'INV-1');
    expect(p.hasMore, isTrue);
  });

  test('Invoice financing eligibility mirrors the backend rules', () {
    expect(Invoice(invoiceJson()).financingBlocker, isNull);
    expect(Invoice(invoiceJson(status: 'DRAFT')).financingBlocker, isNotNull);
    expect(Invoice(invoiceJson(paidBase: '1')).financingBlocker, isNotNull);
    expect(Invoice(invoiceJson(financing: 'REQUESTED')).financingBlocker, isNotNull);
    expect(Invoice(invoiceJson(due: '2000-01-01')).financingBlocker, isNotNull);
  });

  test('Offer parses the documented example', () {
    final o = Offer({
      'id': 'o1', 'invoice_id': 'i1', 'invoice_number': 'INV-2', 'business_name': 'Acme', 'business_verified': true,
      'status': 'REQUESTED', 'display_status': 'SUBMITTED', 'is_overdue': false, 'face_value': '100', 'face_value_base': '100000000',
      'advance': '90', 'advance_base': '90000000', 'discount_bps': 1000, 'token_decimals': 6, 'maturity_date': '2026-12-05',
      'funding_deadline': '2026-11-08T12:57:47Z', 'onchain_offer_id': null, 'disclosure': 'risk',
    });
    expect(o.discountPercent, '10.00');
    expect(o.advanceBase, BigInt.from(90000000));
    expect(o.onchainId, isNull);
  });

  test('TxVerification stages', () {
    TxVerification t(String s) => TxVerification({'tx_hash': '0x1', 'stage': s, 'detail': '', 'confirmations': 0, 'required_confirmations': 3, 'explorer_url': '', 'events': []});
    expect(t('verified').verified, isTrue);
    expect(t('failed').terminalFailure, isTrue);
    expect(t('rejected').terminalFailure, isTrue);
    expect(t('submitted').verified, isFalse);
    expect(t('not_found').terminalFailure, isFalse);
  });

  test('Profile role helpers come from the parsed backend value only', () {
    final p = Profile({'id': 'u', 'role': 'admin', 'investor_verification': 'unverified'});
    expect(p.isAdmin, isTrue);
    expect(p.isMerchant, isFalse);
  });
}
