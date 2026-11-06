import 'package:flutter/material.dart';

/// Design tokens: white / black / NEXA BILLFLOW-logo colours (navy + teal), one type scale, 8-pt spacing.
class Tokens {
  // Sampled from the logo artwork.
  static const blue = Color(0xFF002A64); // logo navy (primary)
  static const blueDeep = Color(0xFF00214C);
  static const teal = Color(0xFF01988E); // logo teal (accent)
  static const tealDeep = Color(0xFF01806E);
  static const ink = Color(0xFF0A0F1A); // near-black text
  static const slate = Color(0xFF5B6472);
  static const bgLight = Color(0xFFFFFFFF);
  static const surfaceTint = Color(0xFFF4F6F8); // subtle grey for chips / banners on white
  static const success = Color(0xFF01806E);
  static const warning = Color(0xFFB45309);
  static const danger = Color(0xFFB91C1C);
  static const info = Color(0xFF002A64);
  static const radius = 16.0;
  static const gap = 16.0;
}

ThemeData _build(Brightness b) {
  final light = b == Brightness.light;
  final scheme = ColorScheme.fromSeed(seedColor: Tokens.blue, brightness: b).copyWith(
    primary: light ? Tokens.blue : const Color(0xFF2CC4B7),
    onPrimary: light ? Colors.white : Colors.black,
    secondary: Tokens.teal,
    surface: light ? Colors.white : const Color(0xFF0A0A0A),
    onSurface: light ? Tokens.ink : Colors.white,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamilyFallback: const ['Inter', 'SF Pro Text', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial'],
    visualDensity: VisualDensity.standard,
    textTheme: Typography.material2021().black.apply(fontFamilyFallback: const ['Inter', 'Roboto']).copyWith(
          displaySmall: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.5),
          headlineMedium: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.4),
          headlineSmall: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.3),
          titleLarge: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2),
          titleMedium: const TextStyle(fontWeight: FontWeight.w700),
        ).apply(bodyColor: light ? Tokens.ink : Colors.white, displayColor: light ? Tokens.ink : Colors.white),
    colorScheme: scheme,
    scaffoldBackgroundColor: light ? Tokens.bgLight : Colors.black,
    appBarTheme: AppBarTheme(
      backgroundColor: light ? Colors.white : const Color(0xFF111111),
      foregroundColor: light ? Tokens.ink : Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: light ? Tokens.ink : Colors.white),
    ),
    cardTheme: CardThemeData(
      color: light ? Colors.white : const Color(0xFF111111),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
        side: BorderSide(color: light ? const Color(0xFFE5E7EB) : const Color(0xFF262626)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: light ? Colors.white : const Color(0xFF111111),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: light ? const Color(0xFFD1D5DB) : const Color(0xFF3A3A3A))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: light ? const Color(0xFFD1D5DB) : const Color(0xFF3A3A3A))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: scheme.primary, width: 1.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), textStyle: const TextStyle(fontWeight: FontWeight.w600)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: light ? Colors.white : const Color(0xFF111111), indicatorColor: scheme.primary.withValues(alpha: 0.14)),
    dividerTheme: DividerThemeData(color: light ? const Color(0xFFE5E7EB) : const Color(0xFF262626), space: 1),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: light ? const Color(0xFFE5E7EB) : const Color(0xFF262626)),
      selectedColor: scheme.primary.withValues(alpha: .12),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, letterSpacing: .3, color: light ? Tokens.slate : Colors.white70),
      headingRowColor: WidgetStatePropertyAll(light ? Tokens.surfaceTint : const Color(0xFF111111)),
      dividerThickness: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: light ? Colors.white : const Color(0xFF111111),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
  );
}

ThemeData lightTheme() => _build(Brightness.light);
ThemeData darkTheme() => _build(Brightness.dark);
