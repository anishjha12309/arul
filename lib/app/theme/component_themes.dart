import 'package:flutter/material.dart';

import 'tokens.dart';

/// Component themes, kept out of theme.dart so the palette stays readable.
///
/// Material renamed these classes -> always `*ThemeData` and `WidgetStateProperty`, never `Material*`.
/// analysis_options.yaml promotes `deprecated_member_use` to an ERROR -> drifting back cannot compile.
abstract final class ArulComponents {
  /// The app bar. Ivory/ink, flat at rest.
  ///
  /// A black drop shadow is invisible on a near-black surface -> it lifts in light, not in dark.
  /// So the scrolled-under state is an M3 surface TINT, never a shadow.
  static AppBarThemeData appBar(ColorScheme scheme, TextTheme text) =>
      AppBarThemeData(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: Elevation.flat,
        scrolledUnderElevation: Elevation.scrolledUnder,
        surfaceTintColor: scheme.surfaceTint,
        shadowColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurface),
      );

  /// Cards are flat and OUTLINED, never shadowed — see [Elevation].
  /// The raised colour alone is 1.08:1 on ivory -> the hairline is what separates a card, both themes.
  static CardThemeData card(ColorScheme scheme) => CardThemeData(
    color: scheme.surfaceContainerLow,
    surfaceTintColor: Colors.transparent,
    elevation: Elevation.flat,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: Radii.cardShape,
      side: BorderSide(color: scheme.outlineVariant),
    ),
  );

  static BottomSheetThemeData sheet(ColorScheme scheme) => BottomSheetThemeData(
    backgroundColor: scheme.surfaceContainerLow,
    surfaceTintColor: Colors.transparent,
    elevation: Elevation.flat,
    showDragHandle: true,
    dragHandleColor: scheme.outline,
    shape: const RoundedRectangleBorder(borderRadius: Radii.sheetShape),
  );

  static DialogThemeData dialog(ColorScheme scheme, TextTheme text) =>
      DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: Elevation.flat,
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardShape),
      );

  /// A seeded scheme puts the selected segment on `secondaryContainer` — pale pink off a rose seed.
  /// That reads as a different product -> selected is the brand fill, set explicitly.
  static SegmentedButtonThemeData segmented(
    ColorScheme scheme,
    TextStyle? label,
  ) => SegmentedButtonThemeData(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : Colors.transparent,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.onSurface,
      ),
      side: WidgetStateProperty.all(BorderSide(color: scheme.outlineVariant)),
      textStyle: WidgetStateProperty.all(label),
    ),
  );

  /// Category chips.
  ///
  /// A selected ChoiceChip reads `secondarySelectedColor`/`secondaryLabelStyle`, not the first pair.
  /// Setting only the first pair gave onSurfaceVariant on primary, 1.6:1 in dark -> set BOTH pairs.
  /// Measured: idle 5.11:1 (light) / 7.72:1 (dark); selected 8.60:1 / 4.75:1.
  static ChipThemeData chip(ColorScheme scheme, TextTheme text) =>
      ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        secondarySelectedColor: scheme.primary,
        selectedColor: scheme.primary,
        disabledColor: scheme.surfaceContainerHighest,
        labelStyle: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
        secondaryLabelStyle: text.labelLarge?.copyWith(color: scheme.onPrimary),
        checkmarkColor: scheme.onPrimary,
        showCheckmark: false,
        side: BorderSide.none,
        elevation: Elevation.flat,
        pressElevation: Elevation.flat,
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.sm,
        ),
        shape: const StadiumBorder(),
      );

  /// Tabs. Rose indicator, muted inactive label -> selection reads as colour AND weight, never colour alone.
  static TabBarThemeData tabBar(ColorScheme scheme, TextTheme text) =>
      TabBarThemeData(
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        overlayColor: WidgetStatePropertyAll(
          scheme.primary.withValues(alpha: 0.08),
        ),
      );

  /// Material's own buttons — ArulButton is custom and ignores these.
  /// Sheets and dialogs still put real TextButtons on screen -> unthemed, they paint Material purple.
  static FilledButtonThemeData filledButton(
    ColorScheme scheme,
    TextTheme text,
  ) => FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
      disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
      elevation: Elevation.flat,
      minimumSize: const Size(0, 52),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
      textStyle: text.labelLarge,
      shape: const RoundedRectangleBorder(borderRadius: Radii.buttonShape),
    ),
  );

  static TextButtonThemeData textButton(ColorScheme scheme, TextTheme text) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          textStyle: text.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: Radii.buttonShape),
        ),
      );

  static OutlinedButtonThemeData outlinedButton(
    ColorScheme scheme,
    TextTheme text,
  ) => OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: scheme.onSurface,
      side: BorderSide(color: scheme.outline),
      minimumSize: const Size(0, 52),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
      textStyle: text.labelLarge,
      shape: const RoundedRectangleBorder(borderRadius: Radii.buttonShape),
    ),
  );

  static IconButtonThemeData iconButton(ColorScheme scheme) =>
      IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurface,
          highlightColor: scheme.primary.withValues(alpha: 0.10),
        ),
      );

  /// A spinner is a *waiting* signal and rose is the colour of actionable things -> teal, not primary.
  /// Measured 6.14:1 on ivory, 7.84:1 on ink — past the 3:1 a UI component owes.
  static ProgressIndicatorThemeData progress(ColorScheme scheme) =>
      ProgressIndicatorThemeData(
        color: scheme.secondary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 2,
      );

  /// showArulToast() builds its own body over a transparent SnackBar -> this governs only the escapees.
  static SnackBarThemeData snackBar(ColorScheme scheme, TextTheme text) =>
      SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        behavior: SnackBarBehavior.floating,
        elevation: Elevation.flat,
        insetPadding: const EdgeInsets.all(Gap.lg),
        shape: const RoundedRectangleBorder(borderRadius: Radii.buttonShape),
      );

  static ListTileThemeData listTile(TextTheme text, Color muted) =>
      ListTileThemeData(
        iconColor: muted,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall,
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      );

  static DividerThemeData divider(ColorScheme scheme) =>
      DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1);
}
