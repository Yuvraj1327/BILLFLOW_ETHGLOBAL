import 'dart:typed_data';

/// Minimal ABI encoder for the exact call shapes BillFlow needs (static types + one trailing `bytes`).
/// Selectors were derived from docs/abi/*.json (keccak256 of the canonical signature) and are asserted in test/abi_test.dart.
/// This runs only in the client to build calldata for the USER'S wallet to sign. It never holds a key.
class Selectors {
  static const approve = '095ea7b3'; // approve(address,uint256)
  static const allowance = 'dd62ed3e'; // allowance(address,address)
  static const balanceOf = '70a08231'; // balanceOf(address)
  static const decimals = '313ce567'; // decimals()
  static const fund = 'ca1d209d'; // fund(uint256)
  static const repay = '371fd8e6'; // repay(uint256)
  static const payInvoice = 'a87ce778'; // payInvoice((bytes32,bytes32,address,address,uint256,uint256,uint256,uint64),bytes)
  static const registerInvoice = '262e2d59'; // registerInvoice((bytes32,bytes32,bytes32,address,address,uint256,uint64,uint64))
  static const verifyInvoice = '22cb1d15'; // verifyInvoice(uint256,bytes32)
  static const createOffer = 'f7d99efd'; // createOffer(uint256,uint256,uint64)
}

String _strip0x(String s) => s.startsWith('0x') || s.startsWith('0X') ? s.substring(2) : s;

String wordUint(BigInt v) {
  if (v.isNegative) throw ArgumentError('negative uint');
  final h = v.toRadixString(16);
  if (h.length > 64) throw ArgumentError('uint256 overflow');
  return h.padLeft(64, '0');
}

String wordAddress(String a) {
  final h = _strip0x(a).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(h)) throw ArgumentError('bad address $a');
  return h.padLeft(64, '0');
}

String wordBytes32(String b) {
  final h = _strip0x(b).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) throw ArgumentError('bad bytes32 $b');
  return h;
}

BigInt parseUint(String s) => s.startsWith('0x') ? BigInt.parse(_strip0x(s), radix: 16) : BigInt.parse(s);

String _call(String selector, List<String> words) => '0x$selector${words.join()}';

String encodeApprove(String spender, BigInt amount) => _call(Selectors.approve, [wordAddress(spender), wordUint(amount)]);
String encodeAllowance(String owner, String spender) => _call(Selectors.allowance, [wordAddress(owner), wordAddress(spender)]);
String encodeBalanceOf(String owner) => _call(Selectors.balanceOf, [wordAddress(owner)]);
String encodeDecimals() => '0x${Selectors.decimals}';
String encodeFund(BigInt invoiceId) => _call(Selectors.fund, [wordUint(invoiceId)]);
String encodeRepay(BigInt invoiceId) => _call(Selectors.repay, [wordUint(invoiceId)]);
String encodeVerifyInvoice(BigInt id, String debtorAckRef) => _call(Selectors.verifyInvoice, [wordUint(id), wordBytes32(debtorAckRef)]);
String encodeCreateOffer(BigInt id, BigInt advance, BigInt fundingDeadline) =>
    _call(Selectors.createOffer, [wordUint(id), wordUint(advance), wordUint(fundingDeadline)]);

/// `q` is the backend's `quote` object (strings). The tuple is fully static, so it is inlined; the signature is the only dynamic part.
String encodePayInvoice(Map<String, dynamic> q, String signatureHex) {
  final sig = _strip0x(signatureHex).toLowerCase();
  if (sig.isEmpty || sig.length.isOdd || !RegExp(r'^[0-9a-f]+$').hasMatch(sig)) throw ArgumentError('bad signature');
  final sigLen = sig.length ~/ 2;
  final padded = sig.padRight(((sigLen + 31) ~/ 32) * 64, '0');
  const headWords = 9; // 8 tuple words + 1 offset word
  return _call(Selectors.payInvoice, [
    wordBytes32(q['invoiceId'] as String),
    wordBytes32(q['invoiceHash'] as String),
    wordAddress(q['merchant'] as String),
    wordAddress(q['payer'] as String),
    wordUint(parseUint('${q['amount']}')),
    wordUint(parseUint('${q['invoiceTotal']}')),
    wordUint(parseUint('${q['nonce']}')),
    wordUint(parseUint('${q['expiry']}')),
    wordUint(BigInt.from(headWords * 32)),
    wordUint(BigInt.from(sigLen)),
    padded,
  ]);
}

/// `p` is the backend publish-plan `args.p` object for InvoiceFinancing.registerInvoice.
String encodeRegisterInvoice(Map<String, dynamic> p) => _call(Selectors.registerInvoice, [
      wordBytes32(p['invoiceHash'] as String),
      wordBytes32(p['documentHash'] as String),
      wordBytes32(p['debtorRef'] as String),
      wordAddress(p['business'] as String),
      wordAddress(p['debtor'] as String),
      wordUint(parseUint('${p['faceValue']}')),
      wordUint(parseUint('${p['issueDate']}')),
      wordUint(parseUint('${p['dueDate']}')),
    ]);

/// Decodes a single uint256 `eth_call` result.
BigInt decodeUint(String hex) {
  final h = _strip0x(hex);
  return h.isEmpty ? BigInt.zero : BigInt.parse(h, radix: 16);
}

Uint8List hexToBytes(String hex) {
  final h = _strip0x(hex);
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> b) => '0x${b.map((e) => e.toRadixString(16).padLeft(2, '0')).join()}';
