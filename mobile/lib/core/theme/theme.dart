import 'package:flutter/material.dart';
import 'tokens.dart';
import 'typography.dart';

ThemeData kittyTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final ink = isDark ? KittyColors.duskDark : KittyColors.dusk;
  final surface = isDark ? KittyColors.creamDark : KittyColors.cream;
  final muted = isDark ? KittyColors.softDark : KittyColors.soft;
  final accent = isDark ? KittyColors.bowlDark : KittyColors.bowl;

  final textTheme = KittyType.build(ink: ink);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: KittyColors.coral,
      onPrimary: surface,
      secondary: accent,
      onSecondary: surface,
      error: KittyColors.rust,
      onError: Colors.white,
      surface: surface,
      onSurface: ink,
      surfaceContainerHighest: muted,
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: surface,
      foregroundColor: ink,
      centerTitle: false,
      titleTextStyle: textTheme.titleMedium,
    ),
    splashColor: KittyColors.coral.withValues(alpha: 0.08),
    highlightColor: KittyColors.coral.withValues(alpha: 0.04),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: muted.withValues(alpha: 0.6),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      hintStyle: textTheme.bodyLarge?.copyWith(color: ink.withValues(alpha: 0.38)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(KittyRadius.l),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(KittyRadius.l),
        borderSide: BorderSide(color: KittyColors.coral.withValues(alpha: 0.35), width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: KittyColors.coral,
        foregroundColor: surface,
        disabledBackgroundColor: muted,
        disabledForegroundColor: ink.withValues(alpha: 0.3),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(KittyRadius.l),
        ),
        textStyle: textTheme.labelLarge,
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ink.withValues(alpha: 0.7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: textTheme.labelMedium,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: ZoomPageTransitionsBuilder(),
      },
    ),
  );
}
