import 'package:flutter/material.dart';

/// Design tokens: one blue/white palette, one type scale, 8-pt spacing.
class Tokens {
  static const blue = Color(0xFF1D4ED8);
  static const blueDeep = Color(0xFF1E3A8A);
  static const ink = Color(0xFF0F172A);
  static const slate = Color(0xFF64748B);
  static const bgLight = Color(0xFFF5F8FD);
  static const success = Color(0xFF15803D);
  static const warning = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);
  static const info = Color(0xFF1D4ED8);
  static const radius = 14.0;
  static const gap = 16.0;
}

ThemeData _build(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: Tokens.blue, brightness: b, primary: b == Brightness.light ? Tokens.blue : const Color(0xFF8AB4FF));
  final light = b == Brightness.light;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: light ? Tokens.bgLight : const Color(0xFF0B1220),
    appBarTheme: AppBarTheme(
      backgroundColor: light ? Colors.white : const Color(0xFF111A2E),
      foregroundColor: light ? Tokens.ink : Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: light ? Tokens.ink : Colors.white),
    ),
    cardTheme: CardThemeData(
      color: light ? Colors.white : const Color(0xFF111A2E),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
        side: BorderSide(color: light ? const Color(0xFFE3E9F4) : const Color(0xFF223052)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: light ? Colors.white : const Color(0xFF111A2E),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: light ? const Color(0xFFD5DEEE) : const Color(0xFF2B3A5F))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: light ? const Color(0xFFD5DEEE) : const Color(0xFF2B3A5F))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), textStyle: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: light ? Colors.white : const Color(0xFF111A2E), indicatorColor: scheme.primary.withValues(alpha: 0.14)),
    dividerTheme: DividerThemeData(color: light ? const Color(0xFFE3E9F4) : const Color(0xFF223052), space: 1),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
  );
}

ThemeData lightTheme() => _build(Brightness.light);
ThemeData darkTheme() => _build(Brightness.dark);
