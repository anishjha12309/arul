import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import 'tokens.dart';

/// Display and headline tiers are Cinzel, the rest Jost; Indic letters fall back per glyph to Android's Noto.
/// An unset slot falls back to Material's own TextTheme, in its BLACK/WHITE colour rather than ours.
/// So every slot is filled deliberately -> no widget can silently paint outside the palette.
abstract final class ArulType {
  static const _tight = -0.4;

  static const _serif = ArulTokens.serif;

  static const _sans = ArulTokens.sans;

  static TextTheme scale(Color ink, Color muted) => TextTheme(
    displayLarge: TextStyle(
      fontFamily: _serif,
      fontSize: 40,
      height: 1.08,
      letterSpacing: -1.2,
      color: ink,
    ),
    displayMedium: TextStyle(
      fontFamily: _serif,
      fontSize: 34,
      height: 1.1,
      letterSpacing: -1.0,
      color: ink,
    ),
    displaySmall: TextStyle(
      fontFamily: _serif,
      fontSize: 28,
      height: 1.15,
      letterSpacing: -0.8,
      color: ink,
    ),
    headlineLarge: TextStyle(
      fontFamily: _serif,
      fontSize: 26,
      height: 1.2,
      letterSpacing: _tight,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontFamily: _serif,
      fontSize: 23,
      height: 1.2,
      letterSpacing: _tight,
      color: ink,
    ),
    headlineSmall: TextStyle(
      fontFamily: _serif,
      fontSize: 20,
      height: 1.25,
      letterSpacing: 0.3,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontFamily: _sans,
      fontSize: 17,
      height: 1.3,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: ink,
    ),
    titleMedium: TextStyle(
      fontFamily: _sans,
      fontSize: 15,
      height: 1.35,
      fontWeight: FontWeight.w500,
      color: ink,
    ),
    titleSmall: TextStyle(
      fontFamily: _sans,
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w500,
      color: ink,
    ),
    bodyLarge: TextStyle(
      fontFamily: _sans,
      fontSize: 15,
      height: 1.45,
      color: ink,
    ),
    bodyMedium: TextStyle(
      fontFamily: _sans,
      fontSize: 14,
      height: 1.45,
      color: muted,
    ),
    bodySmall: TextStyle(
      fontFamily: _sans,
      fontSize: 12,
      height: 1.4,
      color: muted,
    ),
    labelLarge: TextStyle(
      fontFamily: _sans,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      color: ink,
    ),
    labelMedium: TextStyle(
      fontFamily: _sans,
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      color: ink,
    ),

    labelSmall: TextStyle(
      fontFamily: _sans,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.6,
      color: muted,
    ),
  );

  /// The scale as it must be used OVER MEDIA — inside a scrim, on an arbitrary wallpaper.
  ///
  /// The themed muted tier (#C2B7AE) is only 2.40:1 against the bottom scrim over a bright frame.
  /// Even PURE WHITE tops out near 6:1 in that band -> the scrim cannot pay for dimming text at all.
  /// So the second tier is `ivoryText` (6.42:1 at the guarantee point) -> muting is SIZE and TRACKING.
  /// Valid only inside ArulScrims.bottom's guaranteed band — its bottom ~45%, the metadata block.
  static TextTheme onMedia() => scale(Colors.white, ArulColors.ivoryText);

  /// The wordmark — "Arul", and ONLY "Arul".
  /// Cinzel is Latin-only -> a localized string set in it falls back per glyph, in a face nobody chose.
  /// So this is a factory and NOT a TextTheme slot -> reaching for it has to be a deliberate act.
  static TextStyle wordmark(Color color) => TextStyle(
    fontFamily: _serif,
    fontSize: 40,
    height: 1.1,
    letterSpacing: -0.5,
    color: color,
  );
}
