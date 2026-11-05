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
