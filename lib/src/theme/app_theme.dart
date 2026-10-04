import 'package:flutter/material.dart';

import 'app_tokens.dart';

class AppTheme {
  AppTheme._();

  static const Color lightSeed = Color(0xFF2C1B02);
  static const Color darkSeed = Color(0xFF9C27B0);

  static ThemeData light() => _build(Brightness.light, lightSeed);
  static ThemeData dark() => _build(Brightness.dark, darkSeed);

  static ThemeData _build(Brightness b, Color seed) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    const shape = RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: AppTokens.borderRadiusAll,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: shape)),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
      dialogTheme: const DialogThemeData(shape: shape),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorShape: shape,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    );
  }
}
