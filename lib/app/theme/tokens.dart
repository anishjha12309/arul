import 'package:flutter/material.dart';

/// The ONLY place a raw colour, radius, elevation or gap literal may appear in
/// the `lib/app/theme` layer.
///
/// ── REDESIGN NOTE ────────────────────────────────────────────────────────────
/// The normative token source for the UI redesign is `lib/theme/arul_tokens.dart`
/// ([ArulTokens]) — new screens read from THAT file by role name (maroon / gold /
/// ivory / darkSurface / ctaGreen …). This class is the LEGACY ladder that the
/// ThemeData layer (schemes.dart) and the shared widgets still consume. Its NAMES
/// are kept stable so nothing has to be rewritten at once, but its VALUES have
/// been remapped onto the redesign palette, so no call site renders the old
/// rose/teal seed anymore:
///
///   * `rose*`  → maroon `#7A1E33` (the redesign primary)
///   * `teal*`  → gold `#D4A017` (the redesign accent; there is no teal now)
///   * `tealCta`→ ctaGreen `#1FA75A` (ALL primary CTAs are green in the redesign)
///   * `gold*`  → gold `#D4A017`
///   * `ink*`   → the dark surfaces `#14090C / #1A0B0F / #241014 / #2A1218`
///   * `ivory*` → the light surfaces `#FAF5EC / #FFFFFF …`
///
/// The old naming is retained only to avoid a big-bang rename; prefer
/// [ArulTokens] in any new code.
abstract final class ArulColors {
  // ─── Maroon — the primary (was "rose") ──────────────────────────────────────
  /// Light-mode primary. Maroon `#7A1E33`.
  static const roseDeep = Color(0xFF7A1E33);

  /// Dark-mode primary. Maroon hover `#8D2740` — a touch lighter than [roseDeep]
  /// so it does not vanish against the near-black dark surface.
  static const rose = Color(0xFF8D2740);

  /// Light maroon/rose for TEXT on a dark maroon container, and the muted-logout
  /// label. `#F0C9BA` (README > Settings > Logout dark text).
  static const roseSoft = Color(0xFFF0C9BA);

  static const roseTint = Color(
    0xFFF0DED9,
  ); // light primaryContainer (maroon-tint)
  static const onRoseTint = Color(0xFF2B1116);
  static const roseInk = Color(0xFF3A121B); // dark primaryContainer
  static const onRoseDeep = Color(0xFFFAF5EC);
  static const onRose = Color(0xFFFAF5EC);

  // ─── Gold as secondary (was "teal") ─────────────────────────────────────────
  static const tealDeep = Color(0xFF8A6D12); // light secondary (darkened gold)
  static const teal = Color(0xFFD4A017); // dark secondary (brand gold)

  static const tealSoft = Color(0xFFE8CE8A);

  static const tealTint = Color(0xFFF3E7C4);
  static const onTealTint = Color(0xFF3D3118);
  static const tealInk = Color(0xFF4A3A16);
  static const onTealDeep = Color(0xFF14090C);
  static const onTeal = Color(0xFF14090C);

  /// The commit affordance — ctaGreen `#1FA75A`. README: ALL primary CTAs are
  /// green, white label. (The old teal CTA is gone; the redesign mandates green.)
  static const tealCta = Color(0xFF1FA75A);

  // ─── Gold — temple brass / accent ───────────────────────────────────────────
  /// Darkened gold for tertiary TEXT on ivory (raw gold is too bright as light
  /// text). `#8A6D12`.
  static const goldDeep = Color(0xFF8A6D12);

  /// The brand gold `#D4A017` — highlights, selection borders, premium marks,
  /// icons on dark.
  static const gold = Color(0xFFD4A017);

  /// Softer gold for gold TEXT on a dark ground (tagline, footnotes). `#E8CE8A`.
  static const goldSoft = Color(0xFFE8CE8A);

  static const goldTint = Color(0xFFF3E7C4);
  static const onGoldTint = Color(0xFF3D3118);
  static const goldInk = Color(0xFF4A3A16);
  static const onGoldDeep = Color(0xFFFAF5EC);
  static const onGold = Color(0xFF14090C);

  // ─── Ember — error ──────────────────────────────────────────────────────────
  /// A warm terracotta red, distinct from both maroon and gold so a failure can
  /// never be misread as brand chrome.
  static const emberDeep = Color(0xFFA5341E); // light error
  static const ember = Color(0xFFE08A6E); // dark error

  static const emberSoft = Color(0xFFF0BBAC);

  static const emberTint = Color(0xFFF3CFC4);
  static const onEmberTint = Color(0xFF42251B);
  static const emberInk = Color(0xFF4D2A22);
  static const onEmberDeep = Color(0xFFFFF6F2);
  static const onEmber = Color(0xFF14090C);

  // ─── Dark surface ladder (was "ink") ────────────────────────────────────────
  /// The dark surface / splash background. Maroon-black `#14090C`.
  ///
  /// MIRRORED OUTSIDE DART: android values/colors.xml (`splash_bg`,
  /// `ic_launcher_background`) and the `flutter_native_splash` colours in
  /// pubspec.yaml. All three must change together or the OS splash flashes a
  /// different black than the first Flutter frame.
  static const ink = Color(0xFF14090C);

  /// Sheets / dialogs / toasts on the dark surface. `#1A0B0F`.
  static const inkRaised = Color(0xFF1A0B0F);

  /// Dark sheet gradient top / high-elevation surface. `#241014`.
  static const inkHigh = Color(0xFF241014);

  /// Top of the dark ladder: idle chips, skeleton highlight, tile backfill.
  /// `#2A1218` (README > Feed loading mid-stop).
  static const inkVariant = Color(0xFF2A1218);

  /// Primary text on the dark surface `#FAF5EC`, and the secondary tier `#B9A58F`.
  static const ivoryText = Color(0xFFFAF5EC);
  static const ivoryMuted = Color(0xFFB9A58F);

  static const inkOutline = Color(0xFF6E5C4C); // faint
  static const inkOutlineVariant = Color(0xFF231519); // ≈ row divider, solid

  // ─── Light surface ladder (was "ivory") ─────────────────────────────────────
  /// Light surface / background. Ivory `#FAF5EC`.
  static const ivory = Color(0xFFFAF5EC);
  static const ivoryRaised = Color(0xFFFFFFFF); // cards, sheets, dialogs
  static const ivoryHigh = Color(0xFFF1E7DA);
  static const ivoryVariant = Color(0xFFEDE0CF); // idle chips, tile backfill
  static const ivoryLowest = Color(0xFFFFFFFF);
  static const ivoryContainer = Color(0xFFF5EBDD);
  static const ivoryDim = Color(0xFFEFE3D3);

  /// Primary text on ivory `#2B1116`, and the secondary tier `#8A6F5C`.
  static const inkText = Color(0xFF2B1116);
  static const inkMuted = Color(0xFF8A6F5C);

  static const ivoryOutline = Color(0xFFB09A86); // faint
  static const ivoryOutlineVariant = Color(0xFFE5D6CE); // ≈ card border, solid

  /// Inverse pair (tooltips, and any SnackBar that escapes showArulToast).
  static const inverseLight = Color(0xFF2B1116);

  // ─── Over media ─────────────────────────────────────────────────────────────
  // Chrome that sits on an arbitrary wallpaper defends its own contrast with a
  // translucent dark fill plus a hairline. See ArulScrims for the gradient half.

  /// The fill under a pill / action button / live glyph, ON TOP of a scrim.
  static const mediaFill = Color(0x9914090C); // darkSurface @ 60%

  /// A denser fill for chrome that must work with NO scrim behind it.
  static const mediaFillStrong = Color(0xCC14090C); // darkSurface @ 80%

  /// The hairline that separates chrome from the media behind it.
  static const mediaHairline = Color(0x3AFAF5EC); // ivory @ 23%

  // ─── Legacy names ───────────────────────────────────────────────────────────
  // Still read by lib/app/widgets/** and lib/features/**.

  /// Brand primary. Maroon `#7A1E33`.
  /// Call site: lib/app/widgets/skeleton.dart (sweep highlight).
  static const maroon = roseDeep;

  /// ctaGreen `#1FA75A`. Call sites: button_kind.dart, arul_toast.dart.
  static const cta = tealCta;

  /// Error accent. Call site: lib/app/widgets/arul_toast.dart.
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
