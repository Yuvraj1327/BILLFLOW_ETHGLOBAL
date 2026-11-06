import 'package:billflow/core/utils/format.dart';
import 'package:billflow/core/utils/validators.dart' as v;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toBase / fromBase are exact', () {
    expect(toBase('100', 6), BigInt.from(100000000));
    expect(toBase('1250.5', 6), BigInt.from(1250500000));
    expect(toBase('0.000001', 6), BigInt.one);
    expect(toBase('0.0000001', 6), isNull); // too many decimals
    expect(toBase('abc', 6), isNull);
    expect(toBase('-1', 6), isNull);
    expect(fromBase(BigInt.from(1250500000), 6), '1250.5');
    expect(fromBase(BigInt.from(100000000), 6), '100');
    expect(fromBase(BigInt.one, 6), '0.000001');
    expect(fromBase(BigInt.zero, 6), '0');
  });

  test('fmtAmount groups thousands without doubles', () {
    expect(fmtAmount('1234567.89'), '1,234,567.89');
    expect(fmtAmount('999'), '999');
    expect(fmtAmount(null), '—');
    expect(fmtUsdt('1000'), '1,000 USDT');
  });

  test('short formatters', () {
    expect(shortAddr('0x${'ab' * 20}'), '0xabab…abab');
    expect(shortHash('0x${'cd' * 32}').contains('…'), isTrue);
    expect(titleCase('PARTIALLY_PAID'), 'Partially Paid');
  });

  test('validators', () {
    expect(v.isAddress('0x${'a' * 40}'), isTrue);
    expect(v.isAddress('0x123'), isFalse);
    expect(v.isTxHash('0x${'a' * 64}'), isTrue);
    expect(v.email('a@b.co'), isNull);
    expect(v.email('nope'), isNotNull);
    expect(v.password('short'), isNotNull);
    expect(v.password('longenough1'), isNull);
    expect(v.positiveDecimal('10.5'), isNull);
    expect(v.positiveDecimal('0'), isNotNull);
    expect(v.positiveDecimal('1.1234567'), isNotNull);
    expect(v.positiveDecimal('-3'), isNotNull);
    expect(v.optionalAddress(''), isNull);
    expect(v.optionalAddress('0xzz'), isNotNull);
  });
  test('parsePaymentToken accepts links and bare tokens only', () {
    final t = 'a' * 43;
    expect(v.parsePaymentToken(t), t);
    expect(v.parsePaymentToken(' https://pay.example.com/pay/$t '), t);
    expect(v.parsePaymentToken('https://app.example.com/#/pay/$t'), t);
    expect(v.parsePaymentToken('https://x.io/pay/$t?utm=1'), t);
    expect(v.parsePaymentToken('https://x.io/checkout?token=$t'), t);
    expect(v.parsePaymentToken('https://x.io/pay/short'), isNull);
    expect(v.parsePaymentToken('hello world'), isNull);
    expect(v.parsePaymentToken(''), isNull);
  });
}
