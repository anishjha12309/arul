import 'package:flutter/material.dart';

/// The ONLY place a raw colour, radius, elevation or gap literal may appear.
///
/// The reference app leaked 153 `Color(0xFF…)` literals across 19 screens, which
/// made a rebrand a 19-file edit. Screens here read tokens; they never spell a
/// hex value. Enforced by review, not by the compiler — keep it honest.
///
/// Every hex below is sampled from — or derived from — the splash video
/// (a pink lotus on teal dusk water). Three hues carry the brand, and each one is
/// a real region of that footage, not a colour-wheel derivation:
///
///   * **rose 344°** — the lotus. Primary.
///   * **teal 178°** — the water. Secondary. Measured saturation never exceeds
///     ~40% even at its most vivid, so it is bumped to read as an intentional
///     brand colour rather than a desaturated afterthought.
///   * **gold 40°** — temple brass. Tertiary, and the premium signal. The
///     tightest hue cluster in the whole clip (39–42° across every sample).
///
/// Raw pixel values are NOT used verbatim for text-bearing roles: the lotus runs
/// S 58–94% / V 62–87%, which is both too light to pass 4.5:1 on the ivory
/// surface and too neon on a near-black one. Contrast ratios for every pair are
/// stated on the ColorScheme in schemes.dart.
abstract final class ArulColors {
  // ─── Rose — the lotus (hue 344°) ────────────────────────────────────────────
  /// Light-mode primary. Deepened to V46%/S60% so it clears 4.5:1 on ivory
  /// (8.22:1); the raw petal pixels do not.
  static const roseDeep = Color(0xFF752F42);

  /// Dark-mode primary. Keeps a bright V74% but is desaturated from the measured
  /// ~90% down to 50% — full-saturation rose on a near-black screen glows.
  static const rose = Color(0xFFBD5E78);

  /// Bright rose for TEXT on a dark rose container (and the safe substitute for
  /// `rose` whenever small/thin type would otherwise sit on `ink` — `rose` itself
  /// clears 4.5:1 there by only 0.04).
  static const roseSoft = Color(0xFFE6A1B3);

  static const roseTint = Color(0xFFEBA9BA); // light primaryContainer
  static const onRoseTint = Color(0xFF471B27);
  static const roseInk = Color(0xFF4D2E36); // dark primaryContainer
  static const onRoseDeep = Color(0xFFFFF2F6);
  static const onRose = Color(0xFF12070A);

  // ─── Teal — the water (hue 178°) ────────────────────────────────────────────
  static const tealDeep = Color(0xFF30615F); // light secondary
  static const teal = Color(0xFF6BB3B0); // dark secondary

  /// Bright teal for TEXT on the dark teal container (7.14:1).
  static const tealSoft = Color(0xFFA8E0DF);

  static const tealTint = Color(0xFFB3E5E4);
  static const onTealTint = Color(0xFF1C3D3C);
  static const tealInk = Color(0xFF264544);
  static const onTealDeep = Color(0xFFF2FFFF);
  static const onTeal = Color(0xFF122121);

  /// The commit affordance — a filled "go" button, and the success toast.
  ///
  /// It is ONE token used against BOTH themes' surfaces (button_kind.dart pairs
  /// it with a hardcoded `Colors.white`), so it has to satisfy three constraints
  /// at once, which pins it to a narrow luminance window:
  ///   white label on it        5.12:1  (needs ≥4.5 → L ≤ 0.183)
  ///   fill vs ink surface      3.70:1  (needs ≥3.0 → L ≥ 0.133)
  ///   fill vs ivory surface    4.49:1
  ///   20dp toast icon on inkRaised  3.36:1
  /// It lands at hue 178° S57 V48 — exactly between the two brand teals, which is
  /// why a single value can be correct in light AND dark.
  ///
  /// (The maroon-era CTA was a leaf green, #1FA75A. White on it was 3.12:1 — it
  /// never passed. Do not reinstate a green here.)
  static const tealCta = Color(0xFF347878);

  // ─── Gold — temple brass (hue 40°) ──────────────────────────────────────────
  /// Light-mode tertiary. Darkened to V46%: raw specular gold is far too bright
  /// to pass 4.5:1 as text or an icon on ivory.
  static const goldDeep = Color(0xFF755617);

  /// The brand gold — on ink, gold sings with no correction at all, so this is
  /// close to the raw vivid value (V76%/S60%). Used for the emphasised Apply
  /// ring, premium marks, and the wordmark accent.
  static const gold = Color(0xFFC29B4E);

  /// Gold as TEXT on a dark ground (tagline, footnotes). `gold` is a fill/icon
  /// colour; at 11px on ink it is thin.
  static const goldSoft = Color(0xFFE6CFA1);

  static const goldTint = Color(0xFFEBD2A0);
  static const onGoldTint = Color(0xFF3D3118);
  static const goldInk = Color(0xFF524429);
  static const onGoldDeep = Color(0xFFFCF6E8);
  static const onGold = Color(0xFF292214);

  // ─── Ember — error (hue 16°) ────────────────────────────────────────────────
  /// Hue set to 16° deliberately: far enough from rose (344°) and gold (40°) that
  /// a failure state can never be misread as brand chrome or the premium accent.
  static const emberDeep = Color(0xFF874026); // light error
  static const ember = Color(0xFFB86E53); // dark error

  /// Bright ember for TEXT on the dark ember container (6.62:1).
  static const emberSoft = Color(0xFFE6BBAC);

  static const emberTint = Color(0xFFEDB9A6);
  static const onEmberTint = Color(0xFF42251B);
  static const emberInk = Color(0xFF4D332A);
  static const onEmberDeep = Color(0xFFFFF6F2);
  static const onEmber = Color(0xFF120A07);

  // ─── Ink — the dark surface ladder ──────────────────────────────────────────
  /// The dark surface, the splash background, the feed's ground truth.
  ///
  /// This is the one value NOT hue-matched to a pixel, and that is deliberate.
  /// The frame has two very different darks — cool blue-black water (#111418,
  /// hue 220°) below and warm mauve-grey sky above — so a surface matched to
  /// either one visibly clashes with the other at the splash's edges. Instead it
  /// is built at the PRIMARY's own rose hue (344°) at V7.5%/S18%: dark enough to
  /// sit flush against the video's darkest corners (both measured darks are
  /// V8–10%), while its undertone ties the dark theme to the brand rather than to
  /// an incidental water-black. Reads as near-black; the plum cast is real but
  /// subtle by design.
  ///
  /// MIRRORED OUTSIDE DART: android values/colors.xml (`splash_bg`,
  /// `ic_launcher_background`) and the `flutter_native_splash` colours in
  /// pubspec.yaml. All three must change together or the OS splash flashes a
  /// different black than the first Flutter frame.
  static const ink = Color(0xFF131011);

  /// Cards, sheets, dialogs, toasts on ink. Elevation is expressed as a surface
  /// COLOUR step, not a shadow — a black drop shadow on a near-black surface is
  /// invisible, so a shadow-based system only ever works in one of the two themes.
  static const inkRaised = Color(0xFF1F1A1C);
  static const inkHigh = Color(0xFF251F21);

  /// The top of the dark ladder: idle chips, tile backfill behind a loading image.
  static const inkVariant = Color(0xFF2B2426);

  /// Body text on ink (15.03:1) and the muted tier (9.62:1).
  static const ivoryText = Color(0xFFF0E3D8);
  static const ivoryMuted = Color(0xFFC2B7AE);

  static const inkOutline = Color(0xFF78696D);
  static const inkOutlineVariant = Color(0xFF3D3336);

  // ─── Ivory — the light surface ladder ───────────────────────────────────────
  /// Light surface. Hue 28° — the sky-glow hue from the video — pushed to
  /// V98.5%/S10%. Only the HUE survives from the raw swatch (#c6a690, V78%); a
  /// full-screen background at the raw lightness would be unusable.
  static const ivory = Color(0xFFFBEEE2);
  static const ivoryRaised = Color(0xFFFFF8F1); // cards, sheets, dialogs
  static const ivoryHigh = Color(0xFFF1E1D3);
  static const ivoryVariant = Color(0xFFEDDBCC); // idle chips, tile backfill
  static const ivoryLowest = Color(0xFFFFFFFF);
  static const ivoryContainer = Color(0xFFF6E7DA);
  static const ivoryDim = Color(0xFFE2D3C5);

  /// Body text on ivory (13.48:1) and the muted tier (6.03:1).
  static const inkText = Color(0xFF292420);
  static const inkMuted = Color(0xFF615951);

  static const ivoryOutline = Color(0xFF877D74);
  static const ivoryOutlineVariant = Color(0xFFD1C1B4);

  /// Inverse pair (tooltips, and any SnackBar that escapes showArulToast).
  static const inverseLight = Color(0xFF332C2E);

  // ─── Over media ─────────────────────────────────────────────────────────────
  // Chrome that sits on an arbitrary wallpaper cannot use a themed surface — the
  // ground is not ours. It defends its own contrast with a translucent ink fill
  // plus a hairline. See ArulScrims for the gradient half of this.

  /// The fill under a pill, an action button, or the live glyph, ON TOP of a
  /// scrim. Load-bearing, not decorative: gold on the bottom scrim alone is
  /// 2.2:1 over a white frame, but 4.19:1 once this fill is under it.
  static const mediaFill = Color(0x66000000); // black @ 40%

  /// A denser fill for chrome that must work with NO scrim behind it (the grid's
  /// live glyph sits directly on a tile). White on this clears 10.29:1 even over
  /// a pure-white wallpaper.
  static const mediaFillStrong = Color(0xCC131011); // ink @ 80%

  /// The hairline that separates chrome from the media behind it.
  static const mediaHairline = Color(0x47FFFFFF); // white @ 28%

  // The old flat `scrimStrong` / `scrimSoft` pair is gone. A scrim is not one
  // colour: it is a 4-5 stop alpha ramp whose stops are picked against a measured
  // worst-case ground, and quoting a single stop of it out of context is how you
  // end up putting 11pt text where the ramp is 45% and calling it a scrim. The
  // ramps, and what each one actually guarantees, live in ArulScrims.

  // ─── Legacy names ───────────────────────────────────────────────────────────
  // Still read by lib/app/widgets/** and lib/features/**. Deliberately NOT
  // @Deprecated: analysis_options promotes deprecated_member_use to an ERROR, so
  // annotating these would fail `flutter analyze` at call sites the theme layer
  // is not allowed to edit. Migrate the call sites, then delete this block.

  /// Was Kanjivaram maroon. The brand seed is now the lotus rose.
  /// Call site: lib/app/widgets/skeleton.dart (shimmer highlight).
  static const maroon = roseDeep;

  /// Was a leaf green. See [tealCta] for why a green could never have worked here.
  /// Call sites: lib/app/widgets/button_kind.dart, lib/app/widgets/arul_toast.dart.
  static const cta = tealCta;

  /// Call site: lib/app/widgets/arul_toast.dart (error accent).
  static const danger = ember;
}

/// 4pt grid. Screens use these, never bare numbers.
abstract final class Gap {
  static const xs = 4.0; // icon-to-label micro gaps
  static const sm = 8.0; // grid gutter, chip padding
  static const md = 12.0; // grid screen margin — tighter than elsewhere, to buy
  // tile width back in a 2-column layout
  static const lg = 16.0; // viewer margin, list tile padding
  static const xl = 24.0; // section spacing, sheet padding
  static const xxl = 32.0; // paywall section breaks
  static const huge = 48.0; // splash vertical rhythm
}

/// Corner radii. Generous and consistent = the single cheapest "premium" cue.
abstract final class Radii {
  static const chip = 999.0; // pill
  static const tile =
      12.0; // grid thumbnail — `card` (20) is visibly bulbous on
  // a 190×338 tile; the corner eats the artwork
  static const card = 20.0;
  static const sheet = 28.0;
  static const button = 16.0;

  static const tileShape = BorderRadius.all(Radius.circular(tile));
  static const cardShape = BorderRadius.all(Radius.circular(card));
  static const buttonShape = BorderRadius.all(Radius.circular(button));
  static const sheetShape = BorderRadius.vertical(top: Radius.circular(sheet));
}

/// Elevation.
///
/// Almost everything is flat. Hierarchy comes from surface COLOUR (the ink/ivory
/// ladders above) and a hairline outline — never a drop shadow, because a black
/// shadow on a near-black surface is invisible and a shadow-based system would
/// therefore only work in one of the two themes.
abstract final class Elevation {
  static const flat = 0.0;

  /// The one exception: an app bar with a grid scrolled under it. Rendered as an
  /// M3 surface TINT (ColorScheme.surfaceTint), which IS visible on ink.
  static const scrolledUnder = 3.0;
}
