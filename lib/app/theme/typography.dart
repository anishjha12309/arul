import 'package:flutter/material.dart';

import 'tokens.dart';

/// Type scale.
///
/// `fontFamily` is null everywhere = the platform stack (Roboto plus the Noto
/// fallbacks Android already ships). That is not a cop-out, it is the only
/// correct choice: Arul localises into Tamil, Telugu, Kannada, Malayalam and
/// Hindi, and bundling faces for five Indic scripts would add megabytes to
/// reproduce what the OS renders for free — and a font that covers Latin but not
/// Tamil silently falls back mid-sentence, which looks worse than never having
/// left the system stack.
///
/// So hierarchy has to be bought with size, weight, case, tracking and colour,
/// and nothing else. The moves that do the work here:
///   * a real size jump between tiers (40 → 26 → 21 → 18 → 15), never a 1pt
///     nudge that reads as a mistake;
///   * weight only ever 400 / 600 / 700 — three steps, so each one means
///     something;
///   * NEGATIVE tracking on everything ≥18pt (large system type set at 0 looks
///     loose and default) and WIDE positive tracking + uppercase on the 11pt
///     eyebrow. That eyebrow is the single cheapest "considered" cue in the whole
///     app;
///   * colour as the third axis: onSurface for the thing you read, muted for the
///     thing you glance at.
///
/// Every slot is filled deliberately. An unset slot falls back to Material's own
/// default TextTheme — with its default BLACK/WHITE colour, not ours — so a
/// widget reaching for, say, titleSmall would silently paint outside the palette.
abstract final class ArulType {
  static const _tight = -0.4;

  static TextTheme scale(Color ink, Color muted) => TextTheme(
    // Wordmark / hero numerals only.
    displayLarge: TextStyle(
      fontSize: 48,
      height: 1.08,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.2,
      color: ink,
    ),
    displayMedium: TextStyle(
      fontSize: 40,
      height: 1.1,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.0,
      color: ink,
    ),
    displaySmall: TextStyle(
      fontSize: 32,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
      color: ink,
    ),
    headlineLarge: TextStyle(
      fontSize: 30,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: _tight,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontSize: 26,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: _tight,
      color: ink,
    ),
    // Viewer title, sign-in headline.
    headlineSmall: TextStyle(
      fontSize: 21,
      height: 1.25,
      fontWeight: FontWeight.w700,
      letterSpacing: _tight,
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

    /// Eyebrow / tagline. Wide tracking + uppercase is the one typographic move
    /// that reads "considered" for free.
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.6,
      color: muted,
    ),
  );

  /// The scale as it must be used OVER MEDIA — inside a scrim, on an arbitrary
  /// wallpaper.
  ///
  /// The themed scale is wrong there, and not by a little: its muted tier
  /// (#C2B7AE) is only 2.40:1 against the bottom scrim over a bright frame. The
  /// reason is physical — in the band where the scrim is strong enough to be
  /// worth having, even PURE WHITE tops out around 6:1, so there is simply no
  /// luminance left to spend on "muted". Dimming text over media is a move the
  /// scrim cannot pay for.
  ///
  /// So over media the second tier is a warm off-white (`ivoryText`, 6.42:1 at
  /// the scrim's guarantee point) and the muting comes from SIZE and TRACKING
  /// instead — which is the same lever the rest of this file already leans on.
  ///
  /// Valid anywhere inside ArulScrims.bottom's guaranteed band (its bottom ~45%,
  /// which is exactly the metadata block) — see scrims.dart.
  static TextTheme onMedia() => scale(Colors.white, ArulColors.ivoryText);

  /// The wordmark — "Arul", and ONLY "Arul".
  ///
  /// A serif at display size is the one thing the system stack can give us that
  /// reads as a designed mark rather than as UI text. `'serif'` is a family ALIAS
  /// resolved by Android's font config (it lands on Noto Serif) — it is not a
  /// bundled asset, costs zero bytes, and if a device cannot resolve it the
  /// fallback below puts us straight back on the default stack.
  ///
  /// It must NEVER be applied to a localized string. Noto Serif has no Tamil,
  /// Telugu, Kannada or Malayalam coverage, so a translated string set in it would
  /// fall back per-glyph and render in a different face than the one asked for.
  /// That is why this is a separate factory and not a TextTheme slot: reaching for
  /// it has to be a deliberate act.
  static TextStyle wordmark(Color color) => TextStyle(
    fontFamily: 'serif',
    fontFamilyFallback: const ['Roboto'],
    fontSize: 40,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: color,
  );
}
