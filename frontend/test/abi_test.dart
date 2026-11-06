import 'package:billflow/core/utils/abi.dart';
import 'package:flutter_test/flutter_test.dart';

// NOTE: written without a Flutter SDK available; NOT executed in the build environment. Run `flutter test` to execute.
String w(String hex) => hex.padLeft(64, '0');

void main() {
  test('selectors match keccak256 of the canonical signatures (computed offline from docs/abi)', () {
    expect(Selectors.approve, '095ea7b3');
    expect(Selectors.allowance, 'dd62ed3e');
    expect(Selectors.balanceOf, '70a08231');
    expect(Selectors.decimals, '313ce567');
    expect(Selectors.fund, 'ca1d209d');
    expect(Selectors.repay, '371fd8e6');
    expect(Selectors.payInvoice, 'a87ce778');
    expect(Selectors.registerInvoice, '262e2d59');
    expect(Selectors.verifyInvoice, '22cb1d15');
    expect(Selectors.createOffer, 'f7d99efd');
  });

  test('approve / fund encoding', () {
    final spender = '0x${'ab' * 20}';
    expect(encodeApprove(spender, BigInt.from(100000000)), '0x095ea7b3${w('ab' * 20)}${w('5f5e100')}');
    expect(encodeFund(BigInt.from(7)), '0xca1d209d${w('7')}');
    expect(encodeBalanceOf(spender), '0x70a08231${w('ab' * 20)}');
  });

  test('payInvoice calldata matches the independently computed (Python) vector', () {
    final quote = {
      'invoiceId': '0x${'01' * 32}',
      'invoiceHash': '0x${'02' * 32}',
      'merchant': '0x${'aa' * 20}',
      'payer': '0x${'bb' * 20}',
      'amount': '100000000',
      'invoiceTotal': '100000000',
      'nonce': '12345',
      'expiry': '1893456000',
    };
    final sig = '0x${List.generate(65, (i) => i.toRadixString(16).padLeft(2, '0')).join()}';
    final expected = '0xa87ce778'
        '${'01' * 32}${'02' * 32}${w('aa' * 20)}${w('bb' * 20)}'
        '${w('5f5e100')}${w('5f5e100')}${w('3039')}${w('70dbd880')}'
        '${w('120')}${w('41')}'
        '${List.generate(65, (i) => i.toRadixString(16).padLeft(2, '0')).join().padRight(192, '0')}';
    expect(encodePayInvoice(quote, sig), expected);
  });

  test('rejects malformed addresses / signatures instead of encoding garbage', () {
    expect(() => encodeApprove('0x1234', BigInt.one), throwsA(anything));
    expect(() => encodePayInvoice({'invoiceId': '0x${'01' * 32}'}, 'zz'), throwsA(anything));
  });
}
