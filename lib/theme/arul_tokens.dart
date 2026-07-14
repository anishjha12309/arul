import 'package:flutter/material.dart';

/// ARUL — the single normative design-token source for the UI redesign.
///
/// This file is the machine-readable copy of `design_handoff_arul/README.md`.
/// Every value is annotated with the README line it encodes. Screen code reads
/// tokens from here; it never spells a hex, radius, duration or letter-spacing
/// literal of its own.
///
/// Naming mirrors the README vocabulary (maroon / gold / ivory / darkSurface /
/// ctaGreen / darkTextSecondary / feedTopScrim / silkDark …) so a screen author
/// can consume a token by the same word the design spec uses.
///
/// Where the README gives a RANGE (`.04–.05`, `16–20px`, `50–54px`) both
/// endpoints are exposed when they map to two genuinely different usage sites
/// (e.g. [cardBgDark04] vs [cardBgDark05]); where the range is one decision the
/// chosen value is noted in the token's doc comment.
///
/// Letter-spacing: the README quotes tracking in `em`; Flutter's `letterSpacing`
/// is logical pixels, so every value below is pre-multiplied (`em × fontSize`)
/// and the arithmetic is shown in the comment.
abstract final class ArulTokens {
  ArulTokens._();

  // ───────────────────────────── Brand colors ─────────────────────────────
  // README > Colors.

  /// maroon (primary) — active states, light-theme icons, muted destructive
  /// buttons, confirm CTA. `#7A1E33`.
  static const Color maroon = Color(0xFF7A1E33);

  /// maroon hover / pressed confirm CTA. `#8D2740`.
  static const Color maroonHover = Color(0xFF8D2740);

  /// gold (accent) — highlights, selection borders, premium badging, icons on
  /// dark. `#D4A017`.
  static const Color gold = Color(0xFFD4A017);

  /// ivory — light background AND dark-theme primary text. `#FAF5EC`.
  static const Color ivory = Color(0xFFFAF5EC);

  /// darkSurface — dark background, splash background. `#14090C`.
  static const Color darkSurface = Color(0xFF14090C);

  /// dark sheet surface. `#1A0B0F`.
  static const Color darkSheetSurface = Color(0xFF1A0B0F);

  /// dark sheet gradient top (fades into [darkSheetSurface]). `#241014`.
  static const Color darkSheetGradientTop = Color(0xFF241014);

  /// ctaGreen — ALL primary CTAs. `#1FA75A`.
  static const Color ctaGreen = Color(0xFF1FA75A);

  /// ctaGreen hover / pressed. `#1C9450`.
  static const Color ctaGreenHover = Color(0xFF1C9450);

  // ───────────────────────── Dark theme text ladder ───────────────────────
  // README > Colors > Dark theme.

  /// Dark theme primary text. `#FAF5EC` (== [ivory]).
  static const Color darkText = ivory;

  /// Dark theme secondary text. `#B9A58F`.
  static const Color darkTextSecondary = Color(0xFFB9A58F);

  /// Dark theme body-warm. `#C8AC8D`.
  static const Color darkBodyWarm = Color(0xFFC8AC8D);

  /// Dark theme muted. `#8F7C68`.
  static const Color darkMuted = Color(0xFF8F7C68);

  /// Dark theme faint. `#6E5C4C`.
  static const Color darkFaint = Color(0xFF6E5C4C);

  // ───────────────────── Dark theme surfaces & borders ────────────────────
  // README > Colors > Dark theme. `card bg rgba(250,245,236,.04–.05)` etc.

  /// Card fill, low end. `rgba(250,245,236,.04)`.
  static const Color cardBgDark04 = Color.fromRGBO(250, 245, 236, 0.04);

  /// Card fill, high end. `rgba(250,245,236,.05)`.
  static const Color cardBgDark05 = Color.fromRGBO(250, 245, 236, 0.05);

  /// Card border, low end. `rgba(250,245,236,.09)`.
  static const Color cardBorderDark09 = Color.fromRGBO(250, 245, 236, 0.09);

  /// Card border, high end. `rgba(250,245,236,.14)`.
  static const Color cardBorderDark14 = Color.fromRGBO(250, 245, 236, 0.14);

  /// Row divider. `rgba(250,245,236,.08)`.
  static const Color rowDividerDark = Color.fromRGBO(250, 245, 236, 0.08);

  /// Gold-tint fill, low end. `rgba(212,160,23,.10)`.
  static const Color goldTintFill10 = Color.fromRGBO(212, 160, 23, 0.10);

  /// Gold-tint fill, high end. `rgba(212,160,23,.14)`.
  static const Color goldTintFill14 = Color.fromRGBO(212, 160, 23, 0.14);

  /// Gold border, low end. `rgba(212,160,23,.35)`.
  static const Color goldBorder35 = Color.fromRGBO(212, 160, 23, 0.35);

  /// Gold border, high end. `rgba(212,160,23,.50)`.
  static const Color goldBorder50 = Color.fromRGBO(212, 160, 23, 0.50);

  /// Premium-sheet / plan-card gold border. `rgba(212,160,23,.40)`.
  static const Color goldBorder40 = Color.fromRGBO(212, 160, 23, 0.40);

  /// Premium-plan-card SOLID gold border (1.5px). README > Premium screen.
  static const Color goldBorderSolid = gold;

  // ───────────────────────── Light theme ladder ───────────────────────────
  // README > Colors > Light theme.

  /// Light theme primary text. `#2B1116`.
  static const Color lightText = Color(0xFF2B1116);

  /// Light theme secondary text. `#8A6F5C`.
  static const Color lightSecondary = Color(0xFF8A6F5C);

  /// Light theme body. `#6B5240`.
  static const Color lightBody = Color(0xFF6B5240);

  /// Light theme faint. `#B09A86`.
  static const Color lightFaint = Color(0xFFB09A86);

  /// Light theme card background. `#FFFFFF`.
  static const Color cardBgLight = Color(0xFFFFFFFF);

  /// Light theme card border. `rgba(122,30,51,.12)`.
  static const Color cardBorderLight = Color.fromRGBO(122, 30, 51, 0.12);

  /// Light theme divider. `rgba(122,30,51,.10)`.
  static const Color dividerLight = Color.fromRGBO(122, 30, 51, 0.10);

  /// Maroon-tint fill, low end. `rgba(122,30,51,.07)`.
  static const Color maroonTintFill07 = Color.fromRGBO(122, 30, 51, 0.07);

  /// Maroon-tint fill, high end. `rgba(122,30,51,.08)`.
  static const Color maroonTintFill08 = Color.fromRGBO(122, 30, 51, 0.08);

  /// Light-theme selection / hero border. `rgba(122,30,51,.18)`.
  static const Color maroonBorder18 = Color.fromRGBO(122, 30, 51, 0.18);

  // ────────────────────────────── Scrims ──────────────────────────────────
  // README > Colors > Scrims: all `rgba(20,9,12,x)`. `Color(0x0014090C)` is a
  // transparent darkSurface, so only alpha moves and no grey fringe appears.

  static const Color _scrim0 = Color.fromRGBO(20, 9, 12, 0.0);

  /// Feed top chrome scrim, h130, `.62 → 0`. Extra low-alpha mid-stop kills
  /// banding where the tail meets the wallpaper.
  static const LinearGradient feedTopScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // README is a plain two-stop `.62 → 0`; no mid-stop, or the mid-range
    // reads visibly weaker than the reference.
    colors: [Color.fromRGBO(20, 9, 12, 0.62), _scrim0],
  );

  /// Feed bottom chrome scrim (meta + action rail), h190, `.72 → 0`.
  static const LinearGradient feedBottomScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    // Plain two-stop `.72 → 0` per README (see note on [feedTopScrim]).
    colors: [Color.fromRGBO(20, 9, 12, 0.72), _scrim0],
  );

  /// Splash bottom scrim. README > Splash: `180deg .25 → 0 @35% → 0 @55% → .82`.
  static const LinearGradient splashBottomScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.fromRGBO(20, 9, 12, 0.25),
      _scrim0,
      _scrim0,
      Color.fromRGBO(20, 9, 12, 0.82),
    ],
    stops: [0.0, 0.35, 0.55, 1.0],
  );

  /// Sign-in scrim. README > Sign-in: 3-stop `.28 → 0 (38–62%) → .72`.
  static const LinearGradient signInScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.fromRGBO(20, 9, 12, 0.28),
      _scrim0,
      _scrim0,
      Color.fromRGBO(20, 9, 12, 0.72),
    ],
    stops: [0.0, 0.38, 0.62, 1.0],
  );

  /// Bottom-sheet barrier overlay. README range `.55–.62`; chosen `.58`.
  static const Color sheetOverlay = Color.fromRGBO(20, 9, 12, 0.58);

  /// Dialog barrier overlay. `.60`.
  static const Color dialogOverlay = Color.fromRGBO(20, 9, 12, 0.60);

  // ─────────────────────────── Silk gradients ─────────────────────────────
  // README > Colors > Silk gradients (profile / hero / plan cards).

  /// Silk, dark theme. `135deg rgba(122,30,51,.35) → rgba(212,160,23,.10)`,
  /// paired with [silkBorderDark] (gold 30%).
  static const LinearGradient silkDark = LinearGradient(
    begin: Alignment.topLeft, // 135deg
    end: Alignment.bottomRight,
    colors: [
      Color.fromRGBO(122, 30, 51, 0.35),
      Color.fromRGBO(212, 160, 23, 0.10),
    ],
  );

  /// Silk, light theme. `rgba(122,30,51,.10) → rgba(212,160,23,.10)`, paired
  /// with [silkBorderLight] (maroon 18%).
  static const LinearGradient silkLight = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.fromRGBO(122, 30, 51, 0.10),
      Color.fromRGBO(212, 160, 23, 0.10),
    ],
  );

  /// Silk card border, dark — gold 30%.
  static const Color silkBorderDark = Color.fromRGBO(212, 160, 23, 0.30);

  /// Silk card border, light — maroon 18% (== [maroonBorder18]).
  static const Color silkBorderLight = maroonBorder18;

  /// Dark sheet surface gradient: [darkSheetGradientTop] → [darkSheetSurface].
  /// README > Premium gate: `#241014 → #1A0B0F`.
  static const LinearGradient sheetGradientDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [darkSheetGradientTop, darkSheetSurface],
  );

  /// Feed loading placeholder fill. README > Feed states > Loading:
  /// `110deg #14090C 30% → #2A1218 50% → #14090C 70%`.
  static const Color skeletonBase = darkSurface; // #14090C
  static const Color skeletonHighlight = Color(0xFF2A1218);

  // ─────────────────────────── Text over media ────────────────────────────

  /// Shadow for text/icons sitting directly on media. README > Spacing/misc:
  /// `0 1px 8px rgba(0,0,0,.6)`.
  static const List<Shadow> overMediaShadow = [
    Shadow(offset: Offset(0, 1), blurRadius: 8, color: Color(0x99000000)),
  ];

  // ────────────────────────────── Typography ──────────────────────────────
  // README > Typography. UI = system stack (fontFamily null). Serif =
  // 'Marcellus' (bundled) for the Latin wordmark, screen titles, price/reward
  // numerals and hero headings ONLY — never a localized string.

  /// The bundled display-serif family. Latin-only; must NOT wrap Indic text.
  static const String serif = 'Marcellus';

  /// Splash wordmark "Arul". 44px, Marcellus, ls `.04em` (44 × .04 = 1.76).
  static const TextStyle wordmarkSplash = TextStyle(
    fontFamily: serif,
    fontSize: 44,
    height: 1.05,
    letterSpacing: 1.76,
    color: ivory,
  );

  /// Sign-in wordmark "Arul". 30px, Marcellus.
  static const TextStyle wordmarkSignIn = TextStyle(
    fontFamily: serif,
    fontSize: 30,
    height: 1.1,
    letterSpacing: 1.2, // ≈ .04em
    color: ivory,
  );

  /// Tagline / eyebrow. 11px caps, gold, ls `.42em` (11 × .42 = 4.62).
  /// Apply over an already-uppercased string.
  static const TextStyle tagline = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 4.62,
    color: gold,
  );

  /// Screen title. 22px Marcellus. Colour supplied by the theme at the call
  /// site ([lightText] / [darkText]).
  static const TextStyle screenTitle = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    height: 1.15,
    letterSpacing: 0.3,
  );

  /// Hero heading (refer / premium). 21px Marcellus.
  static const TextStyle heroHeading = TextStyle(
    fontFamily: serif,
    fontSize: 21,
    height: 1.2,
  );

  /// Premium / refer price & reward numerals. Marcellus. Size varies per site
  /// (20–30px per README) — pass `.copyWith(fontSize:)`; default 22.
  static const TextStyle priceNumeral = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    height: 1.15,
  );

  /// Sheet / section title. 17px w600, system stack.
  static const TextStyle sheetTitle = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );

  /// Row title. 15px w500.
  static const TextStyle rowTitle = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );

  /// Row sub-label. 12.5px.
  static const TextStyle rowSub = TextStyle(fontSize: 12.5, height: 1.35);

  /// Body copy. 13.5px, line-height 1.5.
  static const TextStyle body = TextStyle(fontSize: 13.5, height: 1.5);

  /// Caption. 12px.
  static const TextStyle caption = TextStyle(fontSize: 12, height: 1.4);

  /// Category / feed chip, inactive. 13.5px w500.
  static const TextStyle chip = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
  );

  /// Category / feed chip, active. 13.5px w600.
  static const TextStyle chipActive = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
  );

  /// Button label. README range 15–16px; chosen 15px w600. Bump per site with
  /// `.copyWith(fontSize: 16)` where the design calls for 16.
  static const TextStyle button = TextStyle(
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  /// LIVE badge. 10.5px w700, ls `.14em` (10.5 × .14 = 1.47), on [darkSurface].
  static const TextStyle liveBadge = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.47,
    color: darkSurface,
  );

  // ─────────────────────────────── Radii ──────────────────────────────────
  // README > Spacing / radii / misc.

  /// Card corner. README range 18–22; chosen 20.
  static const double cardRadius = 20;

  /// Rows-card corner. 20.
  static const double rowsCardRadius = 20;

  /// Sheet top corner. 24.
  static const double sheetTopRadius = 24;

  /// Input field corner. 14.
  static const double inputRadius = 14;

  /// Chips / buttons / pills. 999 (fully rounded).
  static const double pillRadius = 999;

  /// LIVE badge corner. 4.
  static const double liveBadgeRadius = 4;

  /// Icon-chip corner. 12.
  static const double iconChipRadius = 12;

  // ────────────────────────────── Spacing ─────────────────────────────────

  /// Screen edge padding. 16.
  static const double screenPadding = 16;

  /// Gap between content blocks. 16.
  static const double contentGap = 16;

  /// Card inner padding, low end. 16.
  static const double cardPadding16 = 16;

  /// Card inner padding, high end. 20.
  static const double cardPadding20 = 20;

  // ──────────────────────────── Button heights ────────────────────────────

  /// Primary CTA height, low end. 50.
  static const double ctaHeight50 = 50;

  /// Primary CTA height, mid. 52.
  static const double ctaHeight52 = 52;

  /// Primary CTA height, high end. 54.
  static const double ctaHeight54 = 54;

  /// Sign-in pill height. 56.
  static const double signInPillHeight = 56;

  /// Confirm-dialog button height. 46.
  static const double dialogButtonHeight = 46;

  /// Minimum interactive hit target. 44.
  static const double minHitTarget = 44;

  // ──────────────────────────── Icon chip ─────────────────────────────────
  // README: 40×40 r12, gold-tint (dark) / maroon-tint (light), 21px icon.

  /// Icon-chip box size. 40×40.
  static const double iconChipSize = 40;

  /// Icon-chip glyph size. 21.
  static const double iconChipIconSize = 21;

  // ───────────────────────────── Sheet grabber ────────────────────────────
  // README: 44×4 r2, rgba(250,245,236,.25) dark / rgba(43,17,22,.2) light.

  static const double grabberWidth = 44;
  static const double grabberHeight = 4;
  static const double grabberRadius = 2;
  static const Color grabberColorDark = Color.fromRGBO(250, 245, 236, 0.25);
  static const Color grabberColorLight = Color.fromRGBO(43, 17, 22, 0.20);

  // ─────────────────────────────── Motion ─────────────────────────────────
  // README > Motion. Transform/opacity only — never blur, never ShaderMask.

  /// Chrome recede: fade OUT while swiping. 150ms.
  static const Duration chromeRecedeOut = Duration(milliseconds: 150);

  /// Chrome settle: fade IN on settle, ease-out. 250ms.
  static const Duration chromeSettleIn = Duration(milliseconds: 250);

  /// Sheet entrance (translateY(24)+fade), ease. 300ms.
  static const Duration sheetEnter = Duration(milliseconds: 300);

  /// Dialog entrance (translateY(24)+fade), ease. 250ms.
  static const Duration dialogEnter = Duration(milliseconds: 250);

  /// Premium-nudge auto-dismiss. 2600ms.
  static const Duration nudgeAutoDismiss = Duration(milliseconds: 2600);

  /// Skeleton sliding-gradient loop. 1800ms linear.
  static const Duration skeletonLoop = Duration(milliseconds: 1800);

  /// Splash hairline loader loop. 1600ms linear.
  static const Duration hairlineLoop = Duration(milliseconds: 1600);

  /// The ease-out curve for chrome settle. README: "ease-out".
  static const Curve settleCurve = Curves.easeOut;

  /// The generic ease curve for sheets/dialogs. README: "ease".
  static const Curve sheetCurve = Curves.ease;

  /// Linear loop for the two continuous sweeps (skeleton, hairline).
  static const Curve loopCurve = Curves.linear;

  // ──────────────────────── Splash hairline loader ────────────────────────
  // README > Splash: 120×2px gold with sliding gradient, 1.6s linear loop.

  static const double hairlineWidth = 120;
  static const double hairlineHeight = 2;
}
