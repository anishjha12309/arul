import 'package:flutter/material.dart';

/// ARUL — the single normative design-token source for the UI.
///
/// Screen code reads tokens from here; it never spells a hex, radius, duration
/// or letter-spacing literal of its own.
///
/// Naming follows the design vocabulary (maroon / gold / ivory / darkSurface /
/// ctaGreen / darkTextSecondary / feedTopScrim / silkDark …) so a screen author
/// can consume a token by the same word the design uses.
///
/// Where the design gives a RANGE (`.04–.05`, `16–20px`, `50–54px`) both
/// endpoints are exposed when they map to two genuinely different usage sites
/// (e.g. [cardBgDark04] vs [cardBgDark05]); where the range is one decision the
/// chosen value is noted in the token's doc comment.
///
/// Letter-spacing: the design quotes tracking in `em`; Flutter's `letterSpacing`
/// is logical pixels, so every value below is pre-multiplied (`em × fontSize`)
/// and the arithmetic is shown in the comment.
abstract final class ArulTokens {
  ArulTokens._();

  // ───────────────────────────── Brand colors ─────────────────────────────
  // Spec > Colors.

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
  // Spec > Colors > Dark theme.

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
  // Spec > Colors > Dark theme. `card bg rgba(250,245,236,.04–.05)` etc.

  /// Card fill, low end. `rgba(250,245,236,.04)`.
  static const Color cardBgDark04 = Color.fromRGBO(250, 245, 236, 0.04);

  /// Card fill, high end. `rgba(250,245,236,.05)`.
  static const Color cardBgDark05 = Color.fromRGBO(250, 245, 236, 0.05);

  /// Card border, quietest. `rgba(250,245,236,.08)` — the floating dock's rim,
  /// which only needs to describe an edge because the shadow does the lifting.
  /// Same value as [rowDividerDark]; kept separate because one is a border role
  /// and the other a divider role, and they move independently.
  static const Color cardBorderDark08 = Color.fromRGBO(250, 245, 236, 0.08);

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

  /// Card fill, ringtone-row idle. `rgba(250,245,236,.045)` — the ringtones
  /// handoff's row/chip fill, a hair below [cardBgDark04]/[cardBgDark05].
  static const Color cardBgDark045 = Color.fromRGBO(250, 245, 236, 0.045);

  /// Card border, ringtone chip row. `rgba(250,245,236,.12)` — sits between
  /// [cardBorderDark09] and [cardBorderDark14].
  static const Color cardBorderDark12 = Color.fromRGBO(250, 245, 236, 0.12);

  /// Outlined-control border on dark. `rgba(250,245,236,.22)` — the feed chip's
  /// inactive rim and the ringtone row's play button / "Set" pill.
  static const Color ivoryBorder22 = Color.fromRGBO(250, 245, 236, 0.22);

  /// Outlined-control label on dark. `rgba(250,245,236,.86)` — the ringtone
  /// row's "Set" pill text.
  static const Color ivoryText86 = Color.fromRGBO(250, 245, 236, 0.86);

  /// Gold-tint fill, Earn chip. `rgba(212,160,23,.12)`.
  static const Color goldTintFill12 = Color.fromRGBO(212, 160, 23, 0.12);

  // ───────────────────────── Earn button surface ──────────────────────────
  // Ported from Pakiza's `goldFillSoft` / `goldFillSoftBorder` / `controlLift`.
  // The gradient IS the "shimmer" in the reference art — a soft
  // vertical sheen, not a moving highlight. Alphas and stops are Pakiza's; the
  // gold they are struck from is ARUL's [gold], because a palette is the one
  // thing the two apps deliberately do not share (CLAUDE.md §0).

  /// Earn button fill, LIGHT. White falling to cream, exactly as Pakiza draws
  /// it — the sheen comes from the step, so neither stop is tinted gold.
  static const LinearGradient earnFillLight = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFFFF), Color(0xFFF8F0DC)],
  );

  /// Earn button fill, DARK. [gold] at `.20` falling to `.08`.
  static const LinearGradient earnFillDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.fromRGBO(212, 160, 23, 0.20),
      Color.fromRGBO(212, 160, 23, 0.08),
    ],
  );

  /// Earn button rim, light `.38` / dark `.35`.
  static const Color earnBorderLight = Color.fromRGBO(212, 160, 23, 0.38);
  static const Color earnBorderDark = Color.fromRGBO(212, 160, 23, 0.35);

  /// Barely-there lift under a LIGHT-theme header control, and null on dark.
  ///
  /// The app is otherwise flat by design, but the light theme's Earn button
  /// starts at pure white on a cream ground, where a rim alone leaves it
  /// looking painted on rather than raised. Pakiza's `controlLift`, struck from
  /// Arul's ink instead of Pakiza's.
  static const List<BoxShadow> controlLift = [
    BoxShadow(
      color: Color.fromRGBO(43, 17, 22, 0.05),
      blurRadius: 6,
      offset: Offset(0, 2),
    ),
  ];

  /// Gold-tint fill, dock active tab. `rgba(212,160,23,.13)`.
  static const Color goldTintFill13 = Color.fromRGBO(212, 160, 23, 0.13);

  /// Gold border, low end. `rgba(212,160,23,.35)`.
  static const Color goldBorder35 = Color.fromRGBO(212, 160, 23, 0.35);

  /// Gold border, Earn chip + dock active tab. `rgba(212,160,23,.45)`.
  static const Color goldBorder45 = Color.fromRGBO(212, 160, 23, 0.45);

  /// Gold border, now-playing ringtone row. `rgba(212,160,23,.52)`.
  static const Color goldBorder52 = Color.fromRGBO(212, 160, 23, 0.52);

  /// Gold border, high end. `rgba(212,160,23,.50)`.
  static const Color goldBorder50 = Color.fromRGBO(212, 160, 23, 0.50);

  /// Premium-sheet / plan-card gold border. `rgba(212,160,23,.40)`.
  static const Color goldBorder40 = Color.fromRGBO(212, 160, 23, 0.40);

  /// Premium-plan-card SOLID gold border (1.5px). Spec > Premium screen.
  static const Color goldBorderSolid = gold;

  // ───────────────────────── Light theme ladder ───────────────────────────
  // Spec > Colors > Light theme.

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

  /// Light-theme dock rim. `rgba(122,30,51,.08)` — quieter than
  /// [cardBorderLight] because the dock already carries a drop shadow.
  static const Color maroonBorder08 = Color.fromRGBO(122, 30, 51, 0.08);

  // ──────────────── Ringtones: now-playing + dock chrome ──────────────────
  // From the ringtones design handoff (external; these values ARE the record).
  // Roles the rest of the system had no equivalent for.

  /// The now-playing row's title on the LIGHT theme. `#A3760F` — [gold] itself
  /// fails contrast on a white card, so the design darkens it for light only;
  /// dark stays on [gold].
  static const Color nowPlayingTitleLight = Color(0xFFA3760F);

  // ─────────────────────────── Gold ink on light ──────────────────────────

  /// Gold TEXT/glyph ink on a LIGHT surface. `#A3760F`.
  ///
  /// Same value as [nowPlayingTitleLight] and the same cause — [gold] does not
  /// carry on ivory — but a different role, so they move independently: that
  /// one is a list row's playing state, this one is a gold-led control's label
  /// (the Earn pill). Anything gold-on-light that is TYPE, not fill, reads this.
  static const Color goldInkLight = Color(0xFFA3760F);

  /// The floating dock's surface on DARK. `#1B1215` — deliberately a step
  /// warmer/lighter than [darkSurface] so the capsule separates from the feed
  /// behind it without a rim doing the work. Light uses [cardBgLight].
  static const Color dockFillDark = Color(0xFF1B1215);

  /// The dock's active-tab cell on LIGHT. `#F0DCAA` — a solid pale gold; the
  /// dark theme uses the translucent [goldTintFill13] instead.
  static const Color dockActiveFillLight = Color(0xFFF0DCAA);

  /// Dock drop shadow, dark. `0 16px 38px rgba(0,0,0,.6)`.
  static const List<BoxShadow> dockShadowDark = [
    BoxShadow(
      offset: Offset(0, 16),
      blurRadius: 38,
      color: Color.fromRGBO(0, 0, 0, 0.6),
    ),
  ];

  /// Dock drop shadow, light. `0 14px 34px rgba(43,17,22,.14)`.
  static const List<BoxShadow> dockShadowLight = [
    BoxShadow(
      offset: Offset(0, 14),
      blurRadius: 34,
      color: Color.fromRGBO(43, 17, 22, 0.14),
    ),
  ];

  /// The gold halo around a now-playing row's pause button.
  ///
  /// The handoff asks for `0 0 14px rgba(212,160,23,.35)`, and the dock's
  /// active cell for a second `0 0 20px` halo. On a phone rather than a design
  /// canvas those two read as haze: a 20px gold blur on a near-black capsule
  /// fogs the tab's edge, and stacked with the button's halo the dark theme
  /// looked smeared. The dock's is GONE — its cell has fill and a rim, which is
  /// enough — and this one is halved to a tight contact glow that still says
  /// "lit" without bleeding into the row.
  static const List<BoxShadow> nowPlayingButtonGlow = [
    BoxShadow(blurRadius: 8, color: Color.fromRGBO(212, 160, 23, 0.18)),
  ];

  // ────────────────────────────── Scrims ──────────────────────────────────
  // Spec > Colors > Scrims: all `rgba(20,9,12,x)`. `Color(0x0014090C)` is a
  // transparent darkSurface, so only alpha moves and no grey fringe appears.

  static const Color _scrim0 = Color.fromRGBO(20, 9, 12, 0.0);

  /// Feed top chrome scrim, h130, `.62 → 0`. Extra low-alpha mid-stop kills
  /// banding where the tail meets the wallpaper.
  static const LinearGradient feedTopScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // The spec is a plain two-stop `.62 → 0`; no mid-stop, or the mid-range
    // reads visibly weaker than the reference.
    colors: [Color.fromRGBO(20, 9, 12, 0.62), _scrim0],
  );

  /// Feed bottom chrome scrim (meta + action rail), h190, `.72 → 0`.
  static const LinearGradient feedBottomScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    // Plain two-stop `.72 → 0` per spec (see note on [feedTopScrim]).
    colors: [Color.fromRGBO(20, 9, 12, 0.72), _scrim0],
  );

  /// Splash bottom scrim. Spec > Splash: `180deg .25 → 0 @35% → 0 @55% → .82`.
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

  /// Sign-in scrim. Spec > Sign-in: 3-stop `.28 → 0 (38–62%) → .72`.
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

  /// Bottom-sheet barrier overlay. spec range `.55–.62`; chosen `.58`.
  static const Color sheetOverlay = Color.fromRGBO(20, 9, 12, 0.58);

  /// Dialog barrier overlay. `.60`.
  static const Color dialogOverlay = Color.fromRGBO(20, 9, 12, 0.60);

  // ─────────────────────────── Silk gradients ─────────────────────────────
  // Spec > Colors > Silk gradients (profile / hero / plan cards).

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
  /// Spec > Premium gate: `#241014 → #1A0B0F`.
  static const LinearGradient sheetGradientDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [darkSheetGradientTop, darkSheetSurface],
  );

  /// Feed loading placeholder fill. Spec > Feed states > Loading:
  /// `110deg #14090C 30% → #2A1218 50% → #14090C 70%`.
  static const Color skeletonBase = darkSurface; // #14090C
  static const Color skeletonHighlight = Color(0xFF2A1218);

  // ─────────────────────────── Text over media ────────────────────────────

  /// Shadow for text/icons sitting directly on media. Spec > Spacing/misc:
  /// `0 1px 8px rgba(0,0,0,.6)`.
  static const List<Shadow> overMediaShadow = [
    Shadow(offset: Offset(0, 1), blurRadius: 8, color: Color(0x99000000)),
  ];

  /// Shadow for the feed action-rail icons (Apply / Share). The single
  /// [overMediaShadow] lets an ivory glyph wash out over pale wallpapers
  /// (white temples, bright sky). This stacks a tight, near-opaque contact
  /// halo — which hugs the glyph edge and reads as separation on light media —
  /// under a broader soft spread that keeps it grounded over dark media. Result:
  /// the icon carries its own contrast on ANY background without a chip or
  /// border breaking the chromeless rail.
  static const List<Shadow> railIconShadow = [
    Shadow(blurRadius: 3, color: Color(0xE6000000)),
    Shadow(offset: Offset(0, 1), blurRadius: 10, color: Color(0xB3000000)),
  ];

  // ────────────────────────────── Typography ──────────────────────────────
  // Spec > Typography. UI = system stack (fontFamily null). Serif =
  // 'Marcellus' (bundled) for the Latin wordmark, screen titles, price/reward
  // numerals and hero headings ONLY — never a localized string.

  /// The bundled display-serif family. Latin-only; must NOT wrap Indic text.
  static const String serif = 'Marcellus';

  /// Splash wordmark "Arul". 54px, Marcellus, ls `.04em` (54 × .04 = 2.16).
  /// Was 44px under a 44px gopuram mark; with the mark gone the type carries
  /// the splash alone, so it takes the weight — and stays the largest wordmark
  /// in the app, above the 38px sign-in.
  static const TextStyle wordmarkSplash = TextStyle(
    fontFamily: serif,
    fontSize: 54,
    height: 1.05,
    letterSpacing: 2.16,
    color: ivory,
  );

  /// Sign-in wordmark "Arul". 38px, Marcellus. Was 30px when a 34px gopuram
  /// mark sat above it; with the mark gone the type is the only brand element
  /// on the screen, so it takes the weight (still clearly below the 44px
  /// splash, which keeps its mark).
  static const TextStyle wordmarkSignIn = TextStyle(
    fontFamily: serif,
    fontSize: 38,
    height: 1.1,
    letterSpacing: 1.52, // ≈ .04em
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

  /// The title in a top-level tab's header band ([ArulScreenHeader]). 26px
  /// Marcellus, ls `.04em` (26 × .04 = 1.04).
  ///
  /// ONE size for all three tabs. They cross-fade into each other, so a title
  /// that resized between them read as the whole screen jumping. Do not tune
  /// this per screen — change it here and all three move together.
  ///
  /// Was 24 (the wallpaper feed's original metric) until 2026-08-06. The band
  /// itself is unchanged at [headerControlSize]: 26 × 1.15 line height is 29.9,
  /// which still clears 34, so the type grew without the header growing and the
  /// reel below it did not move. That headroom runs out around 29 — past there
  /// the band has to grow too, and growing the band resizes the reel card.
  static const TextStyle screenHeaderTitle = TextStyle(
    fontFamily: serif,
    fontSize: 26,
    height: 1.15,
    letterSpacing: 1.04,
  );

  /// The WORDMARK in the wallpaper feed's header band — "Arul", 28px Marcellus,
  /// ls `.04em` (28 × .04 = 1.12).
  ///
  /// The one deliberate exception to "one size for all three tabs". Ringtones
  /// and Settings show a page TITLE; the feed shows the brand, and a wordmark
  /// that matched the labels around it read as a third tab name rather than as
  /// the app's own mark. It is a different kind of object, so it gets its own
  /// token instead of a per-screen override of [screenHeaderTitle].
  ///
  /// 28 is near the ceiling: `28 × 1.15 = 32.2` inside a [headerControlSize]
  /// band of 34 leaves 1.8 total, and the feed spends some of that dropping the
  /// mark ([ArulScreenHeader.titleDrop]). Past ~29 the line box exceeds the band
  /// and the Row overflows — grow the band first if this ever needs to.
  static const TextStyle wordmarkHeader = TextStyle(
    fontFamily: serif,
    fontSize: 28,
    height: 1.15,
    letterSpacing: 1.12,
  );

  /// Hero heading (refer / premium). 21px Marcellus.
  static const TextStyle heroHeading = TextStyle(
    fontFamily: serif,
    fontSize: 21,
    height: 1.2,
  );

  /// Premium / refer price & reward numerals. Marcellus. Size varies per site
  /// (20–30px per spec) — pass `.copyWith(fontSize:)`; default 22.
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

  /// Row title with the list's optical tracking. 15px w500, ls `.005em`
  /// (15 × .005 = 0.075) — the ringtone row, where a single ellipsised line
  /// needs the extra air that a two-line [rowTitle] block does not.
  static const TextStyle rowTitleTracked = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.075,
  );

  /// Row sub-label. 12.5px.
  static const TextStyle rowSub = TextStyle(fontSize: 12.5, height: 1.35);

  /// Floating-dock label, inactive. 12px w500, ls `.2`.
  ///
  /// The tracking is the point: every other small label in the app carries the
  /// theme's `labelMedium`/`labelSmall` tracking, and a dock label set at 0
  /// read as a different typeface sitting under the same screen. Size dropped
  /// from the handoff's 12.5 to 12 so three labels — one of them "Wallpapers" —
  /// sit in their thirds without FittedBox having to shrink them on a 360dp
  /// phone, which is what actually made the dock look off-family.
  static const TextStyle dockLabel = TextStyle(
    fontSize: 12,
    height: 1.15,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );

  /// Floating-dock label, active. 12px w600, ls `.2`.
  static const TextStyle dockLabelActive = TextStyle(
    fontSize: 12,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );

  /// Body copy. 13.5px, line-height 1.5.
  static const TextStyle body = TextStyle(fontSize: 13.5, height: 1.5);

  /// Caption. 12px.
  static const TextStyle caption = TextStyle(fontSize: 12, height: 1.4);

  /// Category / feed chip, inactive. 13.5px w500.
  static const TextStyle chip = TextStyle(
    fontSize: 13.5,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w500,
  );

  /// Category / feed chip, active. 13.5px w600.
  static const TextStyle chipActive = TextStyle(
    fontSize: 13.5,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w600,
  );

  // Why both chip styles pin `height` and `leadingDistribution`, when the rest
  // of this file leaves line-height to the theme:
  //
  // A `Text` merges its style into the ambient `DefaultTextStyle`, which in a
  // MaterialApp is `bodyMedium` — and ours carries `height: 1.45`. So a chip
  // label with no height of its own got a 19.6px line box for 13.5px of type,
  // and Flutter's DEFAULT leading distribution is `proportional`: it hands the
  // 6px of slack out in the font's own ascent:descent ratio, ~79% of it above
  // the baseline. Centring that box centres the SLACK, not the letters, so
  // every chip label and the Earn pill's sat ~2.7px low inside a 34px pill —
  // obvious next to an icon that really is centred.
  //
  // `height: 1` makes the box the type, and `even` splits what is left equally.
  // Both fixed-height chip rows and the Earn pill come out actually centred.
  // Anything else that centres one of these styles in a box of its own gets it
  // right for free; a control that SIZES to the label instead now measures ~6px
  // shorter, which is why the surface chip's padding was re-cut to match.

  /// Button label. spec range 15–16px; chosen 15px w600. Bump per site with
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
  // Spec > Spacing / radii / misc.

  /// Card corner. spec range 18–22; chosen 20.
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

  /// List-row corner (the ringtone row card). 15 — tighter than [cardRadius],
  /// because a 66-tall row with a 20 radius reads as a lozenge.
  static const double rowRadius = 15;

  /// Cover-art corner (the ringtone medallion). 13.
  static const double coverRadius = 13;

  /// Floating-dock corner. 26.
  static const double dockRadius = 26;

  /// The dock's active-tab cell corner. 18.
  static const double dockActiveTabRadius = 18;

  // ────────────────────────────── Spacing ─────────────────────────────────

  /// Screen edge padding. 16.
  static const double screenPadding = 16;

  /// Gap between content blocks. 16.
  static const double contentGap = 16;

  /// Card inner padding, low end. 16.
  static const double cardPadding16 = 16;

  /// Card inner padding, high end. 20.
  static const double cardPadding20 = 20;

  // ────────────────────── Top-level tab header band ───────────────────────
  // One band for Wallpapers / Ringtones / Settings — see [ArulScreenHeader].
  // These ARE the wallpaper feed's existing metrics; changing them moves the
  // reel, whose card geometry is solved from the height left below the band.

  /// Drop above the header's title row. 6.
  static const double headerTopPadding = 6;

  /// Gap below the header band before a tab's own content. 8.
  static const double headerBottomPadding = 8;

  /// The height of the band, and of every control that sits in it. 34.
  ///
  /// It briefly went to 42 to match Pakiza's header controls and came back:
  /// the handoff draws the Earn button at the SAME height as the category chips
  /// under it, and 34 is what those are. It is also the ONE number the reel's
  /// card geometry is solved against (`feed_card_geometry.dart` derives
  /// everything from the height left below the band), so this is the value that
  /// keeps the card its designed size.
  static const double headerControlSize = 34;

  /// Header control corner. 14 — Pakiza's `AppRadius.headerButton`. NOT
  /// [pillRadius]: the Earn button is a rounded rectangle, not a capsule, and
  /// that is most of why it reads as a button rather than a chip.
  static const double headerButtonRadius = 14;

  /// Gap between a tab's chip row and the content below it. 18.
  ///
  /// One value for both browse tabs. At 10 the chips sat almost on top of the
  /// content and the browse row read as part of the list rather than as chrome
  /// above it.
  static const double chipsBottomGap = 20;

  /// The air ABOVE the chip row, on top of [headerBottomPadding].
  ///
  /// The chip row is meant to sit in equal air, and it did not: the title band
  /// left only [headerBottomPadding] (8) above it while the drop to the content
  /// below was 33, so the row rode high in its own band. These two constants
  /// now resolve to the same gap either side — `headerBottomPadding + this ==
  /// chipsBottomGap` — and the pair sums to what the old lopsided pair summed
  /// to, so the reel below did not resize when the row was recentred.
  static const double chipsTopGap = chipsBottomGap - headerBottomPadding;

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

  // ───────────────────────── Floating dock geometry ───────────────────────
  // Constraints in docs/ui-direction.md §Dock; these values are the record.
  // The dock overlays the branch content (Scaffold.extendBody), so these are
  // also what a scrolling list must clear — see [listBottomInsetUnderDock].

  /// Dock capsule height. 78.
  static const double dockHeight = 78;

  /// Dock inset from the screen's left/right edges. 18.
  static const double dockSideInset = 18;

  /// Dock inset above the bottom safe area. 14.
  static const double dockBottomInset = 14;

  /// Horizontal padding inside the dock capsule. 10.
  static const double dockInnerPadding = 10;

  /// The height of one tab's column inside the capsule. 58.
  static const double dockTabHeight = 58;

  /// Dock icon size. 22.
  static const double dockIconSize = 22;

  /// Gap between a dock tab's icon and its label. 6.
  static const double dockTabGap = 6;

  /// Bottom padding a scrollable owes the floating dock so its last item stays
  /// reachable. 120 — the handoff's number, and comfortably clear of
  /// [dockHeight] + [dockBottomInset].
  static const double listBottomInsetUnderDock = 120;

  /// How opaque the fade behind the dock becomes. `.95`, not 1: a hairline of
  /// the content below still shows through, which reads as depth rather than as
  /// a pasted-on bar.
  static const double dockScrimAlpha = 0.95;

  /// Where that fade reaches full strength, as a fraction of its own height.
  /// `.42` — content dissolves on the way in instead of meeting a hard edge.
  static const double dockScrimStop = 0.42;

  // ──────────────────────────── Icon chip ─────────────────────────────────
  // Spec: 40×40 r12, gold-tint (dark) / maroon-tint (light), 21px icon.

  /// Icon-chip box size. 40×40.
  static const double iconChipSize = 40;

  /// Icon-chip glyph size. 21.
  static const double iconChipIconSize = 21;

  // ───────────────────────────── Sheet grabber ────────────────────────────
  // Spec: 44×4 r2, rgba(250,245,236,.25) dark / rgba(43,17,22,.2) light.

  static const double grabberWidth = 44;
  static const double grabberHeight = 4;
  static const double grabberRadius = 2;
  static const Color grabberColorDark = Color.fromRGBO(250, 245, 236, 0.25);
  static const Color grabberColorLight = Color.fromRGBO(43, 17, 22, 0.20);

  // ─────────────────────────────── Motion ─────────────────────────────────
  // Spec > Motion. Transform/opacity only — never blur, never ShaderMask.

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

  /// Cross-fade between two dock branches. 200ms — long enough to read as a
  /// dissolve rather than a cut, short enough that a tab still feels instant.
  static const Duration tabSwitch = Duration(milliseconds: 200);

  /// The now-playing diya's flame sway + glow pulse. 1100ms ease-in-out,
  /// alternating (so one full there-and-back is 2200ms).
  static const Duration diyaFlicker = Duration(milliseconds: 1100);

  /// The ease-out curve for chrome settle. spec: "ease-out".
  static const Curve settleCurve = Curves.easeOut;

  /// The generic ease curve for sheets/dialogs. spec: "ease".
  static const Curve sheetCurve = Curves.ease;

  /// Linear loop for the two continuous sweeps (skeleton, hairline).
  static const Curve loopCurve = Curves.linear;

  // ──────────────────────── Splash hairline loader ────────────────────────
  // Spec > Splash: 120×2px gold with sliding gradient, 1.6s linear loop.

  static const double hairlineWidth = 120;
  static const double hairlineHeight = 2;
}
