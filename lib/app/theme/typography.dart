import 'package:flutter/material.dart';

import 'tokens.dart';

/// Type scale.
///
/// `fontFamily` is null everywhere = the platform stack (Roboto plus Android's Noto fallbacks).
/// Bundling faces for five Indic scripts adds megabytes to reproduce what the OS renders for free.
/// A face covering Latin but not Tamil falls back mid-sentence -> worse than never leaving the stack.
/// So hierarchy is bought with size, weight, case, tracking and colour, and nothing else:
///   * a real size jump per tier (40 → 26 → 21 → 18 → 15), never a 1pt nudge that reads as a mistake;
///   * weight only ever 400 / 600 / 700 -> three steps, so each one means something;
///   * NEGATIVE tracking on everything ≥18pt — large system type set at 0 looks loose and default;
///   * WIDE tracking + uppercase on the 11pt eyebrow — the cheapest "considered" cue in the app;
///   * colour as the third axis: onSurface for what you read, muted for what you glance at.
///
/// An unset slot falls back to Material's own TextTheme, in its BLACK/WHITE colour rather than ours.
/// So every slot is filled deliberately -> no widget can silently paint outside the palette.
abstract final class ArulType {
  static const _tight = -0.4;

  /// The bundled display serif. Latin-only -> it must never wrap a localized string.
  /// Used by the display/headline tiers and [wordmark], nothing else.
  static const _serif = 'Marcellus';

  static TextTheme scale(Color ink, Color muted) => TextTheme(
    // Display / hero headings — Marcellus (redesign screen titles & hero copy).
    displayLarge: TextStyle(
      fontFamily: _serif,
      fontSize: 48,
      height: 1.08,
      letterSpacing: -1.2,
      color: ink,
    ),
    displayMedium: TextStyle(
      fontFamily: _serif,
      fontSize: 40,
      height: 1.1,
      letterSpacing: -1.0,
      color: ink,
    ),
    displaySmall: TextStyle(
      fontFamily: _serif,
      fontSize: 32,
      height: 1.15,
      letterSpacing: -0.8,
      color: ink,
    ),
    headlineLarge: TextStyle(
      fontFamily: _serif,
      fontSize: 30,
      height: 1.2,
      letterSpacing: _tight,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontFamily: _serif,
      fontSize: 26,
      height: 1.2,
      letterSpacing: _tight,
      color: ink,
    ),
    // Viewer title, sign-in headline. Marcellus, 22px (redesign screen title).
    headlineSmall: TextStyle(
      fontFamily: _serif,
      fontSize: 22,
      height: 1.25,
      letterSpacing: 0.3,
      color: ink,
    ),
    // App-bar title, sheet title.
    titleLarge: TextStyle(
      fontSize: 18,
      height: 1.3,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: ink,
    ),
    // Apply-sheet rows, list tiles.
    titleMedium: TextStyle(
      fontSize: 15,
      height: 1.35,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
    titleSmall: TextStyle(
      fontSize: 13,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: muted),
    bodySmall: TextStyle(fontSize: 12, height: 1.4, color: muted),
    // Buttons.
    labelLarge: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: ink,
    ),
    // Tab / chip labels.
    labelMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: ink,
    ),

    /// Eyebrow / tagline.
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
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
  ///
  /// A serif at display size reads as a designed mark rather than as UI text.
  /// Marcellus is Latin-only -> a localized string set in it falls back per glyph, in a face nobody chose.
  /// So this is a factory and NOT a TextTheme slot -> reaching for it has to be a deliberate act.
  static TextStyle wordmark(Color color) => TextStyle(
    fontFamily: _serif,
    fontSize: 40,
    height: 1.1,
    letterSpacing: -0.5,
    color: color,
  );
}
