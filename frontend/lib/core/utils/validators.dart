final _addr = RegExp(r'^0x[0-9a-fA-F]{40}$');
final _hash = RegExp(r'^0x[0-9a-fA-F]{64}$');
final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

bool isAddress(String? v) => v != null && _addr.hasMatch(v.trim());
bool isTxHash(String? v) => v != null && _hash.hasMatch(v.trim());

String? required(String? v, [String label = 'This field']) => (v == null || v.trim().isEmpty) ? '$label is required' : null;
String? email(String? v) => (v == null || !_email.hasMatch(v.trim())) ? 'Enter a valid email address' : null;
String? password(String? v) => (v == null || v.length < 8) ? 'Use at least 8 characters' : null;
String? optionalAddress(String? v) => (v == null || v.trim().isEmpty || isAddress(v)) ? null : 'Enter a valid 0x… wallet address';
String? requiredAddress(String? v) => isAddress(v) ? null : 'Enter a valid 0x… wallet address';

String? positiveDecimal(String? v, {int maxDecimals = 6, String label = 'Amount'}) {
  final s = (v ?? '').trim();
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return '$label must be a number like 100 or 100.50';
  final frac = s.contains('.') ? s.split('.')[1].length : 0;
  if (frac > maxDecimals) return 'At most $maxDecimals decimal places';
  if (RegExp(r'^0+(\.0+)?$').hasMatch(s)) return '$label must be greater than zero';
  return null;
}

final _payToken = RegExp(r'^[A-Za-z0-9_\-]{32,128}$');

/// Extracts the payment-link token from a pasted checkout URL (path or `#/pay/…` hash form) or a bare token. Null if none.
String? parsePaymentToken(String? input) {
  final s = (input ?? '').trim();
  if (s.isEmpty) return null;
  if (_payToken.hasMatch(s)) return s;
  final uri = Uri.tryParse(s);
  if (uri == null) return null;
  final candidates = [uri.pathSegments, if (uri.fragment.isNotEmpty) Uri.tryParse(uri.fragment.startsWith('/') ? uri.fragment : '/${uri.fragment}')?.pathSegments ?? const <String>[]];
  for (final segs in candidates) {
    final i = segs.lastIndexOf('pay');
    if (i >= 0 && i + 1 < segs.length && _payToken.hasMatch(segs[i + 1])) return segs[i + 1];
  }
  final q = uri.queryParameters['token'];
  return q != null && _payToken.hasMatch(q) ? q : null;
}
