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

  /// Sign-in scrim. Re-cut from Spec > Sign-in's 3-stop `.28 → 0 (38–62%) →
  /// .72`, which assumed the sign-in block hung off the BOTTOM edge and so put
  /// its darkness at 100%.
  ///
  /// Nothing sits at the bottom now. The only free-floating chrome is the
  /// wordmark up top; everything else lives on the silk panel, which carries
  /// its own ground ([mediaFillStrong]) and needs no help. So this ramp does
  /// exactly two jobs and then gets out of the way: a ceiling dark enough for
  /// the wordmark, and a floor that keeps the nav bar from floating — with the
  /// middle left near-clear on purpose, because that band is the artwork the
  /// user is being asked to sign in for.
  ///
  /// Do NOT strengthen the middle to "help" the panel. That trade was measured
  /// the other way: the panel is opaque enough alone, and darkening the centre
  /// only costs the wallpaper.
  static const LinearGradient signInScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.fromRGBO(20, 9, 12, 0.42), // 0%   — wordmark
      Color.fromRGBO(20, 9, 12, 0.06), // 34%  — the anti-banding tail
      Color.fromRGBO(20, 9, 12, 0.10), // 66%  — artwork, near-clear
      Color.fromRGBO(20, 9, 12, 0.46), // 100% — grounds the nav bar
    ],
    stops: [0.0, 0.34, 0.66, 1.0],
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

  /// Fill for chrome that sits on media with NO scrim under it to help.
  /// [darkSurface] at 80%.
  ///
  /// The scrims are tuned for chrome at the screen's EDGES, where a ramp can
  /// reach full strength. A panel floating mid-screen has no such luxury — the
  /// scrim is at its weakest there by design, because that band is the artwork
  /// the user came for. So the panel carries its own ground: this under
  /// [silkDark] holds ivory text at ~10:1 over the worst case an image can
  /// present, a pure white frame, which is the bar `ArulScrims` sets.
  ///
  /// Same value as the legacy `ArulColors.mediaFillStrong` — one role, one
  /// number, so the two ladders cannot drift.
  static const Color mediaFillStrong = Color(0xCC14090C);

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

  /// **The over-media glass recipe** — ivory held as glass: a translucent fill
  /// under a hairline of the same ivory at higher alpha.
  ///
  /// This is the app's language for a control that sits directly on someone's
  /// wallpaper and must not compete with it (the feed's Share circle, the live
  /// mark). Both read these two tokens rather than spelling the rgba twice —
  /// they are the SAME object at two sizes, and a drift between them would
  /// read as two different design systems on one card.
  static const Color overMediaGlassFill = Color.fromRGBO(250, 245, 236, 0.18);
  static const Color overMediaGlassBorder = Color.fromRGBO(250, 245, 236, 0.45);

  /// **Smoked** glass — the fill for chrome sitting on RAW artwork, with no
  /// scrim underneath to supply contrast.
  ///
  /// [overMediaGlassFill] cannot do this job, and no amount of tuning makes it:
  /// it is ivory, ivory is near-white, and a near-white fill over a white
  /// marble temple is invisible at ANY alpha — raising it makes the disc whiter,
  /// not clearer. Chrome with an unknown background behind it has to be the
  /// DARK half of the pair, with the ivory kept for the glyph and the rim.
  ///
  /// [darkSurface] at `.55`, the alpha the legacy ladder's `mediaFillStrong`
  /// was measured at: dense enough to clear 3:1 for an ivory glyph over the
  /// brightest wallpaper in the catalog, translucent enough that the artwork
  /// still reads through it — a lens, never a chip. On dark artwork it all but
  /// vanishes and the rim carries the shape, which is exactly right: the mark
  /// should be quiet where it is already legible.
  ///
  /// Not a shadow. A shadow bleeds OUTSIDE its object onto the wallpaper (which
  /// is why the live mark's was removed); this is contained by the disc.
  static const Color overMediaInkFill = Color.fromRGBO(20, 9, 12, 0.55);

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

  // ════════════════════ Premium paywall ("holy authenticity") ═════════════
  //
  // design_handoff_arul_premium — a SELF-CONTAINED visual system for the one
  // route that sells the product, and the reason every token below carries the
  // `paywall` prefix instead of joining the ladders above.
  //
  // It does not reuse the app palette and must not be "harmonised" into it:
  // its maroon is #7A1F23, a different ink from [maroon] (#7A1E33), and its
  // creams sit warmer than [ivory]. Two paywall screens (monthly / free trial)
  // share one shell, so a value changed here moves both — which is the point.
  //
  // The route is pinned LIGHT (router.dart) and English-only (CLAUDE.md §5), so
  // these are absolute colours with no dark counterpart, by design.

  /// Paywall maroon — headline ink, corner brackets, the trial badge. `#7A1F23`.
  static const Color paywallMaroon = Color(0xFF7A1F23);

  /// CTA gradient, top → bottom. `#8A2427 → #6B191C`.
  static const LinearGradient paywallCtaFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF8A2427), Color(0xFF6B191C)],
  );

  /// CTA rim. Gold 500 `#E8B34B`.
  static const Color paywallGold500 = Color(0xFFE8B34B);

  /// Hairlines, dividers, medallion rims. Gold 600 `#D9A544`.
  static const Color paywallGold600 = Color(0xFFD9A544);

  /// Shrine-panel frame and the rules flanking "PREMIUM". Gold 700 `#C8933A`.
  static const Color paywallGold700 = Color(0xFFC8933A);

  /// The "PREMIUM" eyebrow. Gold deep `#B07F2E`.
  static const Color paywallGoldDeep = Color(0xFFB07F2E);

  /// The shrine panel's inner 1px rule. Gold soft `#E0C58A`.
  static const Color paywallGoldSoft = Color(0xFFE0C58A);

  /// Header block ground. `#FAF5E9` — a half-step warmer than [paywallCream],
  /// which is what separates the brand block from the page without a rule.
  static const Color paywallHeaderBg = Color(0xFFFAF5E9);

  /// Page ground, and the 4px ring inside the shrine frame. `#FDF8EC`.
  static const Color paywallCream = Color(0xFFFDF8EC);

  /// Shrine-panel fill, top → bottom. `#FFFDF6 → #FBF4E2`.
  static const LinearGradient paywallPanelFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFDF6), Color(0xFFFBF4E2)],
  );

  /// Feature-medallion fill. `#FBF1DA`.
  static const Color paywallMedallionFill = Color(0xFFFBF1DA);

  /// Body ink — nav title, feature labels. `#4A3524`.
  static const Color paywallInk = Color(0xFF4A3524);

  /// Secondary ink — social-proof pill, trial lead line, "Selected UPI App".
  /// `#6B5A41`.
  static const Color paywallInkSecondary = Color(0xFF6B5A41);

  /// Muted ink — the fine print under the price, and the UPI caret. `#8B7355`.
  static const Color paywallInkMuted = Color(0xFF8B7355);

  /// Faint ink — the struck-through price and the reassurance line. `#A3926F`.
  static const Color paywallInkFaint = Color(0xFFA3926F);

  /// Gold label ink — "PER MONTH", the tagline. `#A3814A`.
  static const Color paywallInkGold = Color(0xFFA3814A);

  /// The UPI app's own name in the selector chip. `#2C2418`.
  static const Color paywallInkUpi = Color(0xFF2C2418);

  /// CTA label. `#FBF3DE`.
  static const Color paywallOnCta = Color(0xFFFBF3DE);

  /// The trial badge's label on [paywallMaroon]. `#F6E7C8`.
  static const Color paywallOnBadge = Color(0xFFF6E7C8);

  /// Screen rim / back-button rim / UPI chip rim. `#E6D9BD`, `#D9C9A5`.
  static const Color paywallBorderSoft = Color(0xFFE6D9BD);
  static const Color paywallBorderControl = Color(0xFFD9C9A5);

  /// Social-proof pill rim. `#E0D4B4`.
  static const Color paywallBorderPill = Color(0xFFE0D4B4);

  /// The 1px rules flanking "PREMIUM" — gold at the end nearest the word,
  /// fading outward. The right-hand rule is this one mirrored.
  static const LinearGradient paywallBrandRule = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x00C8933A), paywallGold700],
  );

  /// The hairline closing the header block: transparent → gold → transparent.
  static const LinearGradient paywallHeaderHairline = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x00D9A544), paywallGold600, Color(0x00D9A544)],
  );

  /// The vertical hairlines between feature columns — gold at 40%, fading out
  /// top and bottom.
  static const LinearGradient paywallFeatureDivider = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00D9A544), Color(0x66D9A544), Color(0x00D9A544)],
  );

  /// CTA lift. `0 6px 18px rgba(107,25,28,.35)`.
  static const List<BoxShadow> paywallCtaShadow = [
    BoxShadow(
      offset: Offset(0, 6),
      blurRadius: 18,
      color: Color.fromRGBO(107, 25, 28, 0.35),
    ),
  ];

  // ───────────────────── Premium paywall — typography ─────────────────────
  // Three BUNDLED families, paywall-only (pubspec.yaml): Cinzel for display,
  // Lora for everything else, Gelasio for the price numerals. Tracking is
  // quoted in `em` by the handoff and pre-multiplied here, as everywhere above.
  //
  // Every Lora style carries Gelasio in [paywallSerifFallback]: Lora has no
  // U+20B9, and "₹199" in the fine print would otherwise pull a Roboto rupee
  // into a serif sentence.

  /// The display family — "SUBSCRIPTION", "PREMIUM", "ARUL". Weight 500 only.
  static const String paywallDisplayFamily = 'Cinzel';

  /// The text family — everything that is not display or numeral.
  static const String paywallTextFamily = 'Lora';

  /// The numeral family: Georgia's metric-compatible twin, and the only
  /// bundled serif carrying ₹. See pubspec.yaml.
  static const String paywallNumeralFamily = 'Gelasio';

  /// Per-glyph fallback for the text family — supplies ₹ and nothing else.
  static const List<String> paywallSerifFallback = [paywallNumeralFamily];

  /// Nav title "SUBSCRIPTION". Cinzel 500 15px, ls `.18em` (15 × .18 = 2.7).
  /// Apply over an already-uppercased string.
  static const TextStyle paywallNavTitle = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 15,
    height: 1.2,
    letterSpacing: 2.7,
    color: paywallInk,
  );

  /// The "PREMIUM" eyebrow. Cinzel 500 13px, ls `.42em` (13 × .42 = 5.46).
  ///
  /// The tracking is trailing as well as leading, so the word sits ~5px right
  /// of true centre unless the trailing space is trimmed — see the eyebrow's
  /// padding in the paywall view.
  static const TextStyle paywallEyebrow = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    height: 1.2,
    letterSpacing: 5.46,
    color: paywallGoldDeep,
  );

  /// The wordmark "ARUL". Cinzel 500 46px / 1.15.
  static const TextStyle paywallWordmark = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 46,
    height: 1.15,
    color: paywallMaroon,
  );

  /// "Divine grace, every day". Lora italic 400 14px, ls `.06em` (= 0.84).
  static const TextStyle paywallTagline = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontStyle: FontStyle.italic,
    fontSize: 14,
    height: 1.3,
    letterSpacing: 0.84,
    color: paywallInkGold,
  );

  /// The social-proof pill. Lora 400 13px.
  static const TextStyle paywallPill = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 13,
    height: 1.3,
    color: paywallInkSecondary,
  );

  /// "PER MONTH". Lora 500 14px, ls `.28em` (14 × .28 = 3.92). Uppercased at
  /// the call site; the trailing track is trimmed the same way as the eyebrow.
  static const TextStyle paywallPriceCaption = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.2,
    letterSpacing: 3.92,
    color: paywallInkGold,
  );

  /// The trial lead line, "Start your 1-day FREE trial for ₹199".
  /// Lora 500 14px.
  static const TextStyle paywallLead = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.4,
    color: paywallInkSecondary,
  );

  /// "REFUNDED INSTANTLY". Lora 600 11.5px, ls `.2em` (11.5 × .2 = 2.3).
  static const TextStyle paywallBadge = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 11.5,
    height: 1.2,
    letterSpacing: 2.3,
    color: paywallOnBadge,
  );

  /// The fine print under the gold divider. Lora 400 12.5px.
  ///
  /// Both strings it carries are contractually fixed (the handoff) — they state
  /// what the mandate charges, so they ship verbatim.
  static const TextStyle paywallFinePrint = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12.5,
    height: 1.4,
    color: paywallInkMuted,
  );

  /// A feature column's label. Lora 600 13px / 1.35.
  static const TextStyle paywallFeatureLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 13,
    height: 1.35,
    color: paywallInk,
  );

  /// "Selected UPI App". Lora 500 14px.
  static const TextStyle paywallUpiLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.2,
    color: paywallInkSecondary,
  );

  /// The chosen UPI app's name. Lora 600 14px.
  static const TextStyle paywallUpiName = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 14,
    height: 1.2,
    color: paywallInkUpi,
  );

  /// The CTA label. Lora 600 16px, ls `.04em` (16 × .04 = 0.64).
  static const TextStyle paywallCtaLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 16,
    height: 1.2,
    letterSpacing: 0.64,
    color: paywallOnCta,
  );

  /// The line under the CTA. Lora 400 12px.
  static const TextStyle paywallReassurance = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12,
    height: 1.35,
    color: paywallInkFaint,
  );

  // ─────────────────── Premium paywall — price lockup ─────────────────────

  /// The rupee sign, set optically smaller than the amount. 40px.
  static const double paywallRupeeSize = 40;

  /// The amount. 56px.
  static const double paywallAmountSize = 56;

  /// Gap between the two. 4.
  static const double paywallPriceGap = 4;

  // ───────────────────── Premium paywall — geometry ───────────────────────

  /// Back button: a 34px ring with a 17px glyph.
  static const double paywallBackSize = 34;

  /// The rules flanking "PREMIUM": 56 × 1, 12px either side of the word.
  static const double paywallBrandRuleWidth = 56;
  static const double paywallBrandRuleGap = 12;

  /// The header hairline's inset from each edge. 32.
  static const double paywallHairlineInset = 32;

  /// Shrine panel: 28 from the screen edge, 26 below the header.
  static const double paywallPanelInset = 28;
  static const double paywallPanelTopGap = 26;

  /// The cream ring inside the shrine frame (4) and the gold rule inside that
  /// (1) — the handoff's two inset box-shadows, drawn as nested borders.
  static const double paywallPanelRingWidth = 4;

  /// Corner brackets: 14 × 14 at 2px, hung 6px OUTSIDE each corner.
  static const double paywallBracketSize = 14;
  static const double paywallBracketStroke = 2;
  static const double paywallBracketOffset = 6;

  /// The gold rule under the price block. 44 × 2.
  static const double paywallPriceDividerWidth = 44;
  static const double paywallPriceDividerHeight = 2;

  /// Feature medallion: a 48px ring at 1.5px around a 20px line icon drawn at
  /// 1.8px — the handoff's own SVG stroke, kept because a Material glyph at
  /// this size reads heavier than the frame around it.
  static const double paywallMedallionSize = 48;
  static const double paywallMedallionBorder = 1.5;
  static const double paywallFeatureIconSize = 20;
  static const double paywallFeatureIconStroke = 1.8;

  /// CTA: a full-width pill of 16px padding — 52 tall at a 16/1.2 label.
  static const double paywallCtaPadding = 16;

  /// Press feedback: 0.98 for 120ms, ease-out (the handoff's own figures).
  static const double paywallPressScale = 0.98;
  static const Duration paywallPress = Duration(milliseconds: 120);

  /// Opacity for the full-bleed temple illustration behind the paywall.
  static const double paywallOrnamentAlpha = 0.10;

  /// Shared one-pixel stroke for the new ornamental rules.
  static const double paywallOrnamentRuleThickness = 1;

  /// Soft gold used by dotted ornamental leaders and feature dividers.
  static const Color paywallDottedGold = Color(0x99D9A544);

  /// Width of each short rule flanking the navigation title.
  static const double paywallNavOrnamentRuleWidth = 20;

  /// Display size of each navigation-title floret.
  static const double paywallNavFloretSize = 8;

  /// Gap between a navigation floret and its trailing rule.
  static const double paywallNavOrnamentGap = 4;

  /// Gap between each navigation ornament and the title.
  static const double paywallNavTitleOrnamentGap = 8;

  /// Horizontal inset for the temple divider below social proof.
  static const double paywallTempleDividerInset = 32;

  /// Display size of the gopuram at the temple divider's centre.
  static const double paywallTempleDividerGopuramSize = 34;

  /// Display size of the florets terminating the temple divider.
  static const double paywallTempleDividerFloretSize = 8;

  /// Gap between each temple-divider illustration and its rule.
  static const double paywallTempleDividerGap = 8;

  /// Space above the temple divider when social proof is visible.
  static const double paywallTempleDividerTopGap = 20;

  /// Space between the temple divider and the brand lockup.
  static const double paywallTempleDividerBottomGap = 28;

  /// Width of the rule portion of each PREMIUM ornament wing.
  static const double paywallBrandOrnamentRuleWidth = 36;

  /// Display size of the florets beside PREMIUM.
  static const double paywallBrandFloretSize = 9;

  /// Gap between a PREMIUM floret and its rule.
  static const double paywallBrandFloretGap = 5;

  /// Display size of the lotus glyphs flanking the tagline.
  static const double paywallTaglineLotusSize = 15;

  /// Gap between the tagline and its lotus glyphs.
  static const double paywallTaglineOrnamentGap = 8;

  /// Diagonal depth of each chamfer on the shrine panel.
  static const double paywallPanelChamfer = 14;

  /// Inset between the outer and inner shrine-panel rules.
  static const double paywallPanelInnerInset = 5;

  /// Diagonal depth of the shrine panel's inner chamfer.
  static const double paywallPanelInnerChamfer = 10;

  /// Stroke width of both code-drawn shrine-panel rules.
  static const double paywallPanelFrameStroke = 1;

  /// Horizontal content inset that preserves the existing panel geometry.
  static const double paywallPanelContentInset = 21;

  /// Bottom content inset that keeps fine print clear of the lower frame.
  static const double paywallPanelContentBottom = 17;

  /// Display size of the lotus crowning the shrine panel.
  static const double paywallPanelCrownSize = 34;

  /// Distance the shrine-panel crown rises above the frame.
  static const double paywallPanelCrownRise = 13;

  /// Horizontal inset for the shrine-panel crown's dotted leaders.
  static const double paywallPanelCrownInset = 42;

  /// Gap between the shrine-panel lotus and each dotted leader.
  static const double paywallPanelCrownGap = 7;

  /// Cream backing around the shrine-panel lotus where it breaks the frame.
  static const double paywallPanelCrownBackdrop = 5;

  /// Length of each dash in dotted ornamental rules.
  static const double paywallDottedDash = 2;

  /// Gap between dashes in dotted ornamental rules.
  static const double paywallDottedGap = 4;

  /// Display width of the ornamental price divider.
  static const double paywallPriceOrnamentWidth = 48;

  /// Width of each short rule flanking PER MONTH.
  static const double paywallPriceCaptionRuleWidth = 28;

  /// Gap between PER MONTH and its flanking rules.
  static const double paywallPriceCaptionRuleGap = 8;

  /// Display size of the generated illustration inside each medallion.
  static const double paywallFeatureArtSize = 32;

  /// Display size of the florets inset into the CTA.
  static const double paywallCtaFloretSize = 20;

  /// Horizontal inset of the CTA's floret ornaments.
  static const double paywallCtaOrnamentInset = 16;

  /// Display size of the lotus crowning the CTA.
  static const double paywallCtaLotusSize = 32;

  /// Distance the CTA lotus rises above the button edge.
  static const double paywallCtaLotusRise = 16;

  /// Display size of the lotus glyphs flanking reassurance copy.
  static const double paywallFooterLotusSize = 10;

  /// Gap between reassurance copy and its lotus glyphs.
  static const double paywallFooterLotusGap = 4;

  /// Display width of the ornamental footer closing rule.
  static const double paywallFooterRuleWidth = 128;

  /// Gap above the ornamental footer closing rule.
  static const double paywallFooterRuleGap = 6;

  /// Bottom padding after the footer rule, preserving the footer's total height.
  static const double paywallFooterBottomPadding = 8;

  /// Gap between the ARUL wordmark and its lotus-framed tagline.
  static const double paywallBrandTaglineGap = 24;

  /// Bottom padding between the brand lockup and its closing hairline.
  static const double paywallBrandBottomPadding = 13;

  /// Gap between the trial lead sentence and its ₹2 price lockup.
  static const double paywallTrialLeadGap = 2;

  /// Gap between the ₹2 price lockup and the refund badge.
  static const double paywallTrialPriceGap = 4;

  /// Vertical inset inside the trial refund badge.
  static const double paywallTrialBadgeVerticalPadding = 3;

  /// Space above the compact price-divider ornament.
  static const double paywallPriceDividerTopGap = 10;

  /// Space below the price divider before the panel's fine print.
  static const double paywallPriceDividerBottomGap = 4;

  // ───────────────── Premium member page — typography ────────────────────

  /// Member-page navigation title in the paywall display serif.
  static const TextStyle premiumMemberNavTitle = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 25,
    height: 1.15,
    color: paywallMaroon,
  );

  /// Member-page hero headline in the paywall display serif.
  static const TextStyle premiumMemberHeadline = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 25,
    height: 1.18,
    color: paywallMaroon,
  );

  /// Member-page supporting copy in the paywall text serif.
  static const TextStyle premiumMemberBody = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 15,
    height: 1.5,
    color: paywallInkSecondary,
  );

  /// Member-page billing labels in the paywall text serif.
  static const TextStyle premiumMemberBillingLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 15,
    height: 1.3,
    color: paywallInkSecondary,
  );

  /// Member-page billing values in maroon serif.
  static const TextStyle premiumMemberBillingValue = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.3,
    color: paywallMaroon,
  );

  /// Member-page centred renewal reminder.
  static const TextStyle premiumMemberReminder = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12.5,
    height: 1.35,
    color: paywallInkSecondary,
  );

  /// Member-page outlined cancel-action label.
  static const TextStyle premiumMemberCancelLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.2,
    color: paywallMaroon,
  );

  /// Member-page billing footnote.
  static const TextStyle premiumMemberFootnote = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12,
    height: 1.5,
    color: paywallInkMuted,
  );

  /// Member-page positive status-chip label.
  static const TextStyle premiumMemberStatus = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: 0.5,
    color: ctaGreen,
  );

  // ─────────────────── Premium member page — geometry ────────────────────

  /// Horizontal page inset for the member surface.
  static const double premiumMemberPageInset = 20;

  /// Top inset above the member navigation row.
  static const double premiumMemberNavTop = 12;

  /// Bottom inset below the member navigation row.
  static const double premiumMemberNavBottom = 10;

  /// Gap from the back ring to the member navigation title.
  static const double premiumMemberNavGap = 10;

  /// Diameter of the visible ring inside the 44px back hit target.
  static const double premiumMemberBackRingSize = 34;

  /// Stroke width of the member back ring and quiet controls.
  static const double premiumMemberControlStroke = 1;

  /// Member back-arrow glyph size.
  static const double premiumMemberBackIconSize = 21;

  /// Bottom padding of the member page's scrolling content.
  static const double premiumMemberScrollBottom = 24;

  /// Corner radius shared by the member hero and billing card.
  static const double premiumMemberCardRadius = 20;

  /// Horizontal content inset inside the member hero.
  static const double premiumMemberHeroHorizontal = 16;

  /// Vertical content inset inside the member hero.
  static const double premiumMemberHeroVertical = 18;

  /// Display size of the detailed hero gopuram.
  static const double premiumMemberHeroGopuramSize = 64;

  /// Width of each fading rule beside the hero gopuram.
  static const double premiumMemberHeroRuleWidth = 34;

  /// Display size of each floret beside the hero gopuram.
  static const double premiumMemberHeroFloretSize = 8;

  /// Gap within and below the hero's gopuram divider.
  static const double premiumMemberHeroOrnamentGap = 8;

  /// Gap from the gopuram divider to the hero headline.
  static const double premiumMemberHeadlineGap = 10;

  /// Gap from the headline to supporting copy.
  static const double premiumMemberSublineGap = 7;

  /// Gap from supporting copy to the positive status chip.
  static const double premiumMemberStatusGap = 14;

  /// Horizontal inset inside the status chip.
  static const double premiumMemberStatusHorizontal = 13;

  /// Vertical inset inside the status chip.
  static const double premiumMemberStatusVertical = 6;

  /// Fill opacity of the positive member status chip.
  static const double premiumMemberStatusFillAlpha = 0.14;

  /// Border opacity of the positive member status chip.
  static const double premiumMemberStatusBorderAlpha = 0.45;

  /// Gap between the hero and billing card.
  static const double premiumMemberSectionGap = 14;

  /// Horizontal inset inside a billing row.
  static const double premiumMemberRowHorizontal = 16;

  /// Vertical inset inside a billing row.
  static const double premiumMemberRowVertical = 14;

  /// Display size of the gold floret leading a billing label.
  static const double premiumMemberRowFloretSize = 8;

  /// Gap between a billing floret and its label.
  static const double premiumMemberRowLabelGap = 11;

  /// Space between the billing card and its reminder.
  static const double premiumMemberReminderTop = 14;

  /// Display size of each lotus flanking the reminder.
  static const double premiumMemberReminderLotusSize = 15;

  /// Gap between reminder copy and its lotus ornaments.
  static const double premiumMemberReminderGap = 8;

  /// Vertical space between the reminder and cancel action.
  static const double premiumMemberCancelTop = 18;

  /// Height of the outlined member cancel action.
  static const double premiumMemberCancelHeight = 52;

  /// Display size of florets inside the cancel action.
  static const double premiumMemberCancelFloretSize = 20;

  /// Horizontal inset of cancel-action florets.
  static const double premiumMemberCancelFloretInset = 16;

  /// Resting fill opacity of the outlined cancel action.
  static const double premiumMemberCancelFillAlpha = 0.045;

  /// Pressed fill opacity of the outlined cancel action.
  static const double premiumMemberCancelPressedAlpha = 0.10;

  /// Border opacity of the outlined cancel action.
  static const double premiumMemberCancelBorderAlpha = 0.75;

  /// Disabled opacity of the outlined cancel action.
  static const double premiumMemberDisabledAlpha = 0.6;

  /// Size of the cancel action's busy indicator.
  static const double premiumMemberProgressSize = 20;

  /// Stroke width of the cancel action's busy indicator.
  static const double premiumMemberProgressStroke = 2;

  /// Gap from the cancel action to its billing footnote.
  static const double premiumMemberFootnoteTop = 14;

  /// Horizontal inset around the billing footnote.
  static const double premiumMemberFootnoteInset = 18;

  /// Gap from the billing footnote to the closing temple divider.
  static const double premiumMemberFooterTop = 16;

  /// Width of each closing footer rule.
  static const double premiumMemberFooterRuleWidth = 72;

  /// Display size of the closing footer gopuram.
  static const double premiumMemberFooterGopuramSize = 34;

  /// Display size of the florets in the closing footer divider.
  static const double premiumMemberFooterFloretSize = 8;

  /// Gap between pieces of the closing footer divider.
  static const double premiumMemberFooterGap = 7;

  // ─────────────── Premium resubscribe page — typography ─────────────────

  /// Warning status label on the cancelled premium hero.
  static const TextStyle premiumResubscribeStatus = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 12,
    height: 1.2,
    letterSpacing: 0.7,
    color: paywallGoldDeep,
  );

  /// Label above the selected UPI application.
  static const TextStyle premiumResubscribePayUsing = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 15,
    height: 1.3,
    color: paywallInk,
  );

  /// Selected UPI application name.
  static const TextStyle premiumResubscribeUpiName = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.25,
    color: paywallInkUpi,
  );

  /// Change affordance on the selected UPI application.
  static const TextStyle premiumResubscribeChange = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 13,
    height: 1.2,
    color: paywallMaroon,
  );

  /// Price disclosure below the resubscribe CTA.
  static const TextStyle premiumResubscribeFootnote = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12.5,
    height: 1.5,
    color: paywallInkMuted,
  );

  // ───────────────── Premium resubscribe page — geometry ─────────────────

  /// Fill opacity of the cancelled-state warning chip.
  static const double premiumResubscribeStatusFillAlpha = 0.06;

  /// Display size of florets outside the warning chip.
  static const double premiumResubscribeStatusFloretSize = 12;

  /// Gap between each warning-chip floret and the pill.
  static const double premiumResubscribeStatusFloretGap = 10;

  /// Gap above the Pay using section.
  static const double premiumResubscribePayUsingTop = 18;

  /// Gap from Pay using to the UPI selector.
  static const double premiumResubscribePayUsingGap = 8;

  /// Horizontal inset inside the UPI selector.
  static const double premiumResubscribeUpiHorizontal = 14;

  /// Vertical inset inside the UPI selector.
  static const double premiumResubscribeUpiVertical = 11;

  /// Corner radius of the UPI selector.
  static const double premiumResubscribeUpiRadius = 16;

  /// Display size of the selected UPI application icon.
  static const double premiumResubscribeUpiIconSize = 32;

  /// Corner radius of the selected UPI application icon.
  static const double premiumResubscribeUpiIconRadius = 8;

  /// Gap after the selected UPI application icon.
  static const double premiumResubscribeUpiIconGap = 12;

  /// Gap between Change and its chevron.
  static const double premiumResubscribeChangeGap = 3;

  /// Size of the Change chevron.
  static const double premiumResubscribeChevronSize = 20;

  /// Gap from the selected UPI application to the CTA.
  static const double premiumResubscribeCtaTop = 18;

  /// Clearance below the CTA's bottom-edge lotus.
  static const double premiumResubscribeCtaLotusClearance = 13;

  /// Gap from the CTA ornament to the disclosure footnote.
  static const double premiumResubscribeFootnoteTop = 12;

  /// Horizontal inset around the disclosure footnote.
  static const double premiumResubscribeFootnoteInset = 18;

  // ─────────────── Premium celebration sheet — typography ────────────────

  /// Localized celebration title on the system font stack.
  static const TextStyle premiumCelebrateTitle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: paywallMaroon,
  );

  /// Localized celebration body on the system font stack.
  static const TextStyle premiumCelebrateBody = TextStyle(
    fontSize: 14,
    height: 1.5,
    color: paywallInkSecondary,
  );

  /// Localized shrine CTA label on the system font stack.
  static const TextStyle premiumCelebrateCta = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: paywallOnCta,
  );

  /// Localized quiet dismissal label on the system font stack.
  static const TextStyle premiumCelebrateDismiss = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: paywallMaroon,
  );

  // ──────────────── Premium celebration sheet — geometry ────────────────

  /// Horizontal content inset of the premium celebration sheet.
  static const double premiumCelebrateHorizontal = 20;

  /// Top content inset below the sheet grabber.
  static const double premiumCelebrateTop = 2;

  /// Bottom content inset of the premium celebration sheet.
  static const double premiumCelebrateBottom = 18;

  /// Display size of the celebration gopuram.
  static const double premiumCelebrateGopuramSize = 42;

  /// Width of rules flanking the celebration gopuram.
  static const double premiumCelebrateRuleWidth = 28;

  /// Display size of celebration florets.
  static const double premiumCelebrateFloretSize = 8;

  /// Gap between celebration ornament pieces.
  static const double premiumCelebrateOrnamentGap = 7;

  /// Gap from the ornament lockup to the localized title.
  static const double premiumCelebrateTitleTop = 10;

  /// Gap from the localized title to the localized body.
  static const double premiumCelebrateBodyTop = 8;

  /// Gap from the localized body to the gold hairline.
  static const double premiumCelebrateRuleTop = 14;

  /// Width of the celebration gold hairline.
  static const double premiumCelebrateRuleWidthFull = 96;

  /// Gap from the gold hairline to the shrine CTA.
  static const double premiumCelebrateCtaTop = 14;

  /// Clearance below the celebration CTA's lotus.
  static const double premiumCelebrateLotusClearance = 12;

  /// Gap above the quiet dismissal action.
  static const double premiumCelebrateDismissTop = 6;
}
