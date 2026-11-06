import 'package:intl/intl.dart';

final _date = DateFormat('d MMM yyyy');
final _dateTime = DateFormat('d MMM yyyy, HH:mm');

String fmtDate(DateTime? d) => d == null ? '—' : _date.format(d);
String fmtDateTime(DateTime? d) => d == null ? '—' : _dateTime.format(d);

/// Adds thousands separators to a plain decimal string ("1250.5" -> "1,250.5") without going through double.
String fmtAmount(String? s) {
  if (s == null || s.isEmpty) return '—';
  final parts = s.split('.');
  final neg = parts[0].startsWith('-');
  final digits = neg ? parts[0].substring(1) : parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}$buf${parts.length > 1 ? '.${parts[1]}' : ''}';
}

String fmtUsdt(String? s) => s == null ? '—' : '${fmtAmount(s)} USDT';

/// base units -> decimal string, exact (BigInt math; no doubles).
String fromBase(BigInt v, int decimals) {
  if (decimals == 0) return v.toString();
  final neg = v < BigInt.zero;
  final s = v.abs().toString().padLeft(decimals + 1, '0');
  final whole = s.substring(0, s.length - decimals);
  final frac = s.substring(s.length - decimals).replaceFirst(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}$whole${frac.isEmpty ? '' : '.$frac'}';
}

/// decimal string -> base units; null when malformed or too many decimals.
BigInt? toBase(String input, int decimals) {
  final s = input.trim();
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final frac = parts.length > 1 ? parts[1] : '';
  if (frac.length > decimals) return null;
  return BigInt.parse(parts[0] + frac.padRight(decimals, '0'));
}

String shortAddr(String? a) => (a == null || a.length < 12) ? (a ?? '—') : '${a.substring(0, 6)}…${a.substring(a.length - 4)}';
String shortHash(String h) => h.length < 16 ? h : '${h.substring(0, 10)}…${h.substring(h.length - 6)}';

String titleCase(String s) => s.isEmpty ? s : s.split('_').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
