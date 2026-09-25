import 'package:flutter/material.dart';

/// The ONLY place a raw colour, radius, elevation or gap literal may appear in `lib/app/theme`.
///
/// [ArulTokens] in `lib/theme/arul_tokens.dart` is the normative source -> new code reads THAT by role.
/// This is the LEGACY ladder schemes.dart and the shared widgets still consume -> never grow it.
/// Its NAMES are kept only to avoid a big-bang rename; its VALUES are already the redesign palette:
///
///   * `rose*`  → maroon `#7A1E33` (the primary)
///   * `teal*`  → gold `#D4A017` (there is no teal any more)
///   * `tealCta`→ ctaGreen `#1FA75A` (ALL primary CTAs are green)
///   * `gold*`  → gold `#D4A017`
///   * `ink*`   → the dark surfaces `#14090C / #1A0B0F / #241014 / #2A1218`
///   * `ivory*` → the light surfaces `#FAF5EC / #FFFFFF …`
abstract final class ArulColors {
  static const roseDeep = Color(0xFF7A1E33);

  /// Dark-mode primary, maroon hover `#8D2740` — lighter than [roseDeep] or it vanishes on dark.
  static const rose = Color(0xFF8D2740);

  static const roseSoft = Color(0xFFF0C9BA);

  static const roseTint = Color(0xFFF0DED9);
  static const onRoseTint = Color(0xFF2B1116);
  static const roseInk = Color(0xFF3A121B);
  static const onRoseDeep = Color(0xFFFAF5EC);
  static const onRose = Color(0xFFFAF5EC);

  static const tealDeep = Color(0xFF8A6D12);
  static const teal = Color(0xFFD4A017);

  static const tealSoft = Color(0xFFE8CE8A);

  static const tealTint = Color(0xFFF3E7C4);
  static const onTealTint = Color(0xFF3D3118);
  static const tealInk = Color(0xFF4A3A16);
  static const onTealDeep = Color(0xFF14090C);
  static const onTeal = Color(0xFF14090C);

  /// The commit affordance — ctaGreen `#1FA75A`. ALL primary CTAs are green with a white label.
  static const tealCta = Color(0xFF1FA75A);

  /// Darkened gold `#8A6D12` for tertiary TEXT on ivory — raw gold is too bright there.
  static const goldDeep = Color(0xFF8A6D12);

  static const gold = Color(0xFFD4A017);

  static const goldSoft = Color(0xFFE8CE8A);

  static const goldTint = Color(0xFFF3E7C4);
  static const onGoldTint = Color(0xFF3D3118);
  static const goldInk = Color(0xFF4A3A16);
  static const onGoldDeep = Color(0xFFFAF5EC);
  static const onGold = Color(0xFF14090C);

  /// A warm terracotta red, distinct from maroon and gold -> a failure never reads as brand chrome.
  static const emberDeep = Color(0xFFA5341E);
  static const ember = Color(0xFFE08A6E);

  static const emberSoft = Color(0xFFF0BBAC);

  static const emberTint = Color(0xFFF3CFC4);
  static const onEmberTint = Color(0xFF42251B);
  static const emberInk = Color(0xFF4D2A22);
  static const onEmberDeep = Color(0xFFFFF6F2);
  static const onEmber = Color(0xFF14090C);

  /// The dark surface / splash background. Maroon-black `#14090C`.
  ///
  /// MIRRORED OUTSIDE DART in android values/colors.xml and pubspec's `flutter_native_splash`.
  /// All three must change together -> or the OS splash flashes a different black than frame one.
  static const ink = Color(0xFF14090C);

  static const inkRaised = Color(0xFF1A0B0F);

  static const inkHigh = Color(0xFF241014);

  static const inkVariant = Color(0xFF2A1218);

  static const ivoryText = Color(0xFFFAF5EC);
  static const ivoryMuted = Color(0xFFB9A58F);

  static const inkOutline = Color(0xFF6E5C4C);
  static const inkOutlineVariant = Color(0xFF231519);

  static const ivory = Color(0xFFFAF5EC);
  static const ivoryRaised = Color(0xFFFFFFFF);
  static const ivoryHigh = Color(0xFFF1E7DA);
  static const ivoryVariant = Color(0xFFEDE0CF);
  static const ivoryLowest = Color(0xFFFFFFFF);
  static const ivoryContainer = Color(0xFFF5EBDD);
  static const ivoryDim = Color(0xFFEFE3D3);

  static const inkText = Color(0xFF2B1116);
  static const inkMuted = Color(0xFF8A6F5C);

  static const ivoryOutline = Color(0xFFB09A86);
  static const ivoryOutlineVariant = Color(0xFFE5D6CE);

  static const inverseLight = Color(0xFF2B1116);

  // ─── Over media ─────────────────────────────────────────────────────────────
  // Chrome on an arbitrary wallpaper defends its own contrast: translucent dark fill plus a hairline.
  // ArulScrims owns the gradient half.

  static const mediaFill = Color(0x9914090C);

  /// A denser fill for chrome that must work with NO scrim behind it.
  static const mediaFillStrong = Color(0xCC14090C);

  static const mediaHairline = Color(0x3AFAF5EC);

  static const maroon = roseDeep;

  static const cta = tealCta;

  static const danger = ember;
}

/// 4pt grid. Screens use these, never bare numbers.
abstract final class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0; // grid screen margin — tighter than elsewhere, to buy
  // tile width back in a 2-column layout
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const huge = 48.0;
}

/// Corner radii. Generous and consistent = the single cheapest "premium" cue.
abstract final class Radii {
  static const chip = 999.0;
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
/// A black shadow is invisible on a near-black surface -> a shadow system works in one theme only.
/// So hierarchy comes from surface COLOUR and a hairline outline, never a drop shadow.
abstract final class Elevation {
  static const flat = 0.0;

  /// The one exception — an app bar with a grid scrolled under it, as an M3 surface TINT visible on ink.
  static const scrolledUnder = 3.0;
}
