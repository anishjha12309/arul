import 'package:flutter/material.dart';

import 'tokens.dart';

/// The two ColorSchemes, every role spelled out — maroon primary, gold accents, ivory/`#14090C` grounds.
///
/// `fromSeed` rotates hue off the seed for secondary/tertiary -> a maroon seed invents the wrong gold.
/// Gold is a fixed brand accent, not a derivation -> every role is hand-specified here.
/// These roles drive ThemeData chrome only -> screens read exact values from [ArulTokens].
abstract final class ArulSchemes {
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,

    primary: ArulColors.roseDeep, //          8.22:1 on surface
    onPrimary: ArulColors.onRoseDeep, //      8.60:1 on primary
    primaryContainer: ArulColors.roseTint,
    onPrimaryContainer: ArulColors.onRoseTint, // 7.51:1 on primaryContainer

    secondary: ArulColors.tealDeep, //        6.14:1 on surface
    onSecondary: ArulColors.onTealDeep, //    6.84:1 on secondary
    secondaryContainer: ArulColors.tealTint,
    onSecondaryContainer: ArulColors.onTealTint, // 8.55:1

    tertiary: ArulColors.goldDeep, //         5.95:1 on surface
    onTertiary: ArulColors.onGoldDeep, //     6.29:1 on tertiary
    tertiaryContainer: ArulColors.goldTint,
    onTertiaryContainer: ArulColors.onGoldTint, // 8.64:1

    error: ArulColors.emberDeep, //           6.60:1 on surface
    onError: ArulColors.onEmberDeep, //       7.06:1 on error
    errorContainer: ArulColors.emberTint,
    onErrorContainer: ArulColors.onEmberTint, // 8.00:1

    surface: ArulColors.ivory,
    onSurface: ArulColors.inkText, //         13.48:1 on surface
    onSurfaceVariant: ArulColors.inkMuted, //  6.03:1 on surface, 5.11:1 on
    // surfaceContainerHighest — the idle category chip, its worst ground.
    outline: ArulColors.ivoryOutline, //       3.53:1 on surface
    outlineVariant: ArulColors.ivoryOutlineVariant,

    // Container ladder: onSurface ≥10.5:1 and onSurfaceVariant ≥4.7:1 on EVERY step -> sit on any of them.
    surfaceDim: ArulColors.ivoryDim,
    surfaceBright: ArulColors.ivoryRaised,
    surfaceContainerLowest: ArulColors.ivoryLowest,
    surfaceContainerLow: ArulColors.ivoryRaised,
    surfaceContainer: ArulColors.ivoryContainer,
    surfaceContainerHigh: ArulColors.ivoryHigh,
    surfaceContainerHighest: ArulColors.ivoryVariant,

    inverseSurface: ArulColors.inverseLight,
    onInverseSurface: ArulColors.ivory, //    11.96:1
    inversePrimary: ArulColors.rose, //        3.27:1 (UI/large only)

    shadow: Colors.black,
    scrim: Colors.black,

    // Elevation tint — only the app bar's scrolled-under state opts in; every other theme zeroes it.
    surfaceTint: ArulColors.roseDeep,
  );

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,

    // 4.54:1 on surface — the tightest margin in the palette; it clears 4.5 body text only just.
    // For SMALL or THIN type directly on ink reach for roseSoft (#E6A1B3, 8.7:1) instead.
    // Its real use is fill/icon/large text (3:1) — the selected chip, where onPrimary rides at 4.75:1.
    primary: ArulColors.rose,
    onPrimary: ArulColors.onRose, //          4.75:1 on primary
    primaryContainer: ArulColors.roseInk,
    onPrimaryContainer: ArulColors.roseSoft, // 5.75:1 on primaryContainer

    secondary: ArulColors.teal, //            7.84:1 on surface
    onSecondary: ArulColors.onTeal, //        6.88:1 on secondary
    secondaryContainer: ArulColors.tealInk,
    onSecondaryContainer: ArulColors.tealSoft, // 7.14:1

    tertiary: ArulColors.gold, //             7.29:1 on surface
    onTertiary: ArulColors.onGold, //         6.07:1 on tertiary
    tertiaryContainer: ArulColors.goldInk,
    onTertiaryContainer: ArulColors.goldSoft, // 6.22:1

    error: ArulColors.ember, //               4.86:1 on surface
    onError: ArulColors.onEmber, //           5.03:1 on error
    errorContainer: ArulColors.emberInk,
    onErrorContainer: ArulColors.emberSoft, // 6.62:1

    surface: ArulColors.ink,
    onSurface: ArulColors.ivoryText, //       15.03:1 on surface
    onSurfaceVariant: ArulColors.ivoryMuted, // 9.62:1 on surface, 7.72:1 on
    // surfaceContainerHighest
    outline: ArulColors.inkOutline, //         3.64:1 on surface
    outlineVariant: ArulColors.inkOutlineVariant,

    // Dark surface ladder — sheets, cards and dialogs read surfaceContainerLow, the sheet #1A0B0F.
    surfaceDim: ArulColors.ink,
    surfaceBright: Color(0xFF2A1218),
    surfaceContainerLowest: Color(0xFF0D0609),
    surfaceContainerLow: ArulColors.inkRaised, // #1A0B0F
    surfaceContainer: ArulColors.inkRaised,
    surfaceContainerHigh: ArulColors.inkHigh, // #241014
    surfaceContainerHighest: ArulColors.inkVariant, // #2A1218

    inverseSurface: ArulColors.ivoryText,
    onInverseSurface: ArulColors.inverseLight, // 10.83:1
    inversePrimary: ArulColors.roseDeep, //        7.44:1

    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: ArulColors.rose,
  );

  static ColorScheme light() => lightScheme;
  static ColorScheme dark() => darkScheme;

  /// The muted text tier — sub-copy, footnotes, the eyebrow; anywhere the scale wants less than onSurface.

  static const lightMuted = ArulColors.inkMuted; // 6.03:1 on ivory
  static const darkMuted = ArulColors.ivoryMuted; // 9.62:1 on ink
}
