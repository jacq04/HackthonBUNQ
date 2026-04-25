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
    // Inputs sit on the black canvas — solid charcoal fill so the field reads
    // without a border, with an orange focus ring picking up the brand.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark
          ? const Color(0xFF1F1F1F)
          : Colors.white.withValues(alpha: 0.92),
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      hintStyle: textTheme.bodyLarge?.copyWith(color: ink.withValues(alpha: 0.4)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(KittyRadius.l),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(KittyRadius.l),
        borderSide: BorderSide(color: KittyColors.coral, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: KittyColors.coral,
        // Bunq orange demands dark ink for legibility.
        foregroundColor: KittyColors.ink,
        disabledBackgroundColor: muted,
        disabledForegroundColor: ink.withValues(alpha: 0.3),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(KittyRadius.full),
        ),
        textStyle: textTheme.labelLarge,
        elevation: 0,
      ),
    ),
    // Dividers fade to match dark cards.
    dividerTheme: DividerThemeData(
      color: ink.withValues(alpha: 0.08),
      thickness: 1,
      space: 1,
    ),
    iconTheme: IconThemeData(color: ink.withValues(alpha: 0.85)),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: KittyColors.coral,
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
