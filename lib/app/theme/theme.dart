import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'component_themes.dart';
import 'schemes.dart';
import 'typography.dart';

/// Dark is primary (media-first, night sessions), but light is designed, not derived -> its own
/// hand-specified scheme in schemes.dart, its own deepened rose/gold (the dark values fail 4.5:1 on
/// ivory), and a hairline-outlined card treatment dark does not need.
abstract final class ArulTheme {
  /// Both themes are built ONCE, lazily, and reused forever.
  /// Cacheable ONLY because the palette is fixed — no dynamic colour, no wallpaper seeding -> no
  /// input can make a second call differ from the first.
  static final ThemeData _light = _build(
    scheme: ArulSchemes.light(),
    muted: ArulSchemes.lightMuted,
  );

  static final ThemeData _dark = _build(
    scheme: ArulSchemes.dark(),
    muted: ArulSchemes.darkMuted,
  );

  static ThemeData light() => _light;

  static ThemeData dark() => _dark;

  static ThemeData _build({required ColorScheme scheme, required Color muted}) {
    final text = ArulType.scale(scheme.onSurface, muted);
    final isDark = scheme.brightness == Brightness.dark;

    // System-bar ICON brightness must follow the surface -> light icons on the ivory theme make the
    // clock and battery invisible.
    // Bar COLOURS are ignored at targetSdk 35+ -> only brightness and contrast still apply.
    final overlay = SystemUiOverlayStyle(
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    );

    return ThemeData(
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,

      // Predictive back is already the Android default -> pinned only so an edit can't silently swap
      // in Zoom*, which DISABLES the gesture.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),

      appBarTheme: ArulComponents.appBar(
        scheme,
        text,
      ).copyWith(systemOverlayStyle: overlay),
      cardTheme: ArulComponents.card(scheme),
      bottomSheetTheme: ArulComponents.sheet(scheme),
      dialogTheme: ArulComponents.dialog(scheme, text),
      chipTheme: ArulComponents.chip(scheme, text),
      tabBarTheme: ArulComponents.tabBar(scheme, text),
      segmentedButtonTheme: ArulComponents.segmented(scheme, text.labelMedium),
      filledButtonTheme: ArulComponents.filledButton(scheme, text),
      textButtonTheme: ArulComponents.textButton(scheme, text),
      outlinedButtonTheme: ArulComponents.outlinedButton(scheme, text),
      iconButtonTheme: ArulComponents.iconButton(scheme),
      progressIndicatorTheme: ArulComponents.progress(scheme),
      snackBarTheme: ArulComponents.snackBar(scheme, text),
      listTileTheme: ArulComponents.listTile(text, muted),
      dividerTheme: ArulComponents.divider(scheme),
    );
  }
}
