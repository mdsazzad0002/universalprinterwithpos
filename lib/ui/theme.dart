import 'package:flutter/material.dart';

const _seed = Color(0xFF2350D8);

/// Status colors that are not part of the Material color scheme.
const successColor = Color(0xFF16A34A);
const warningColor = Color(0xFFD97706);

/// Hand cursor on anything clickable. Flutter's default shows it only on web;
/// on Linux/Windows buttons would otherwise keep the arrow.
const clickCursor = WidgetStateMouseCursor.clickable;
const _clickStyle = ButtonStyle(mouseCursor: clickCursor);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    primary: dark ? const Color(0xFF9DB4FF) : _seed,
    surface: dark ? const Color(0xFF12151C) : const Color(0xFFF4F6FB),
    surfaceContainerLowest: dark ? const Color(0xFF0D1016) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF1A1E27) : Colors.white,
  );
  final radius = BorderRadius.circular(16);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  // Sizes come from the Material type scale; base.textTheme only carries colors.
  final sized = Typography.englishLike2021.merge(base.textTheme);
  final text = sized.copyWith(
    headlineSmall: sized.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
    titleLarge: sized.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
    titleMedium: sized.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: sized.titleSmall?.copyWith(fontWeight: FontWeight.w600),
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.6)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      mouseCursor: clickCursor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: text.titleSmall?.copyWith(color: scheme.onSurface),
      subtitleTextStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => text.labelMedium?.copyWith(
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
          )),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
      selectedLabelTextStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
      unselectedLabelTextStyle: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ).copyWith(mouseCursor: clickCursor),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ).copyWith(mouseCursor: clickCursor),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))).copyWith(mouseCursor: clickCursor),
    ),
    elevatedButtonTheme: const ElevatedButtonThemeData(style: _clickStyle),
    iconButtonTheme: const IconButtonThemeData(style: _clickStyle),
    segmentedButtonTheme: const SegmentedButtonThemeData(style: _clickStyle),
    menuButtonTheme: const MenuButtonThemeData(style: _clickStyle),
    checkboxTheme: const CheckboxThemeData(mouseCursor: clickCursor),
    radioTheme: const RadioThemeData(mouseCursor: clickCursor),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: radius),
      mouseCursor: clickCursor,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      mouseCursor: clickCursor,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      mouseCursor: clickCursor,
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? const Icon(Icons.check, size: 16) : null,
      ),
    ),
  );
}
