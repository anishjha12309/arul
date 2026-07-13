import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'component_themes.dart';
import 'schemes.dart';
import 'typography.dart';

/// Light + dark, fixed brand palette.
///
/// NEVER seed from device wallpaper / dynamic colour: this app's whole job is
/// showing wallpapers, so a theme that recoloured itself from the user's current
/// one would fight its own content.
///
/// Dark is the primary theme — the product is media-first and most sessions are
/// at night — but light is designed, not derived: it gets its own hand-specified
/// scheme (schemes.dart), its own deepened rose/gold (the dark values fail 4.5:1
/// on ivory), and a hairline-outlined card treatment it needs and dark does not.
abstract final class ArulTheme {
  static ThemeData light() =>
      _build(scheme: ArulSchemes.light(), muted: ArulSchemes.lightMuted);

  static ThemeData dark() =>
      _build(scheme: ArulSchemes.dark(), muted: ArulSchemes.darkMuted);

  static ThemeData _build({required ColorScheme scheme, required Color muted}) {
    final text = ArulType.scale(scheme.onSurface, muted);
    final isDark = scheme.brightness == Brightness.dark;

    // System-bar ICON brightness must follow the surface or the clock and battery
    // go invisible — light icons on the ivory theme is exactly that bug. (Bar
    // COLOURS are ignored at targetSdk 35+; only brightness/contrast still apply.)
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

      // Predictive back IS the Android default since 3.38 — pinned so a future
      // edit can't silently swap in Zoom*, which DISABLES the gesture.
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
