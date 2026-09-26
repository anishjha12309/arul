import 'package:flutter/material.dart';

/// ARUL — the single normative design-token source for the UI.
///
/// Screen code reads tokens from here — it never spells a hex, radius, duration or tracking literal.
/// Naming follows the DESIGN vocabulary -> an author consumes a token by the word the design uses.
/// A design RANGE exposes both endpoints only when they map to two genuinely different usage sites.
/// Where a range is one decision, the chosen value is noted in the token's own doc.
/// The design quotes tracking in `em` and Flutter takes logical pixels.
/// So every value below is pre-multiplied (`em × fontSize`), with the arithmetic in the comment.
abstract final class ArulTokens {
  ArulTokens._();

  static const Color maroon = Color(0xFF7A1E33);

  static const Color maroonHover = Color(0xFF8D2740);

  static const Color gold = Color(0xFFD4A017);

  static const Color ivory = Color(0xFFFAF5EC);

  static const Color darkSurface = Color(0xFF14090C);

  static const Color darkSheetSurface = Color(0xFF1A0B0F);

  static const Color darkSheetGradientTop = Color(0xFF241014);

  static const Color ctaGreen = Color(0xFF1FA75A);

  static const Color ctaGreenHover = Color(0xFF1C9450);

  /// Glyph and label ON a [ctaGreen] fill. Pure white — the ivory reads dirty on green.
  static const Color onCta = Color(0xFFFFFFFF);

  static const Color darkText = ivory;

  static const Color darkTextSecondary = Color(0xFFB9A58F);

  static const Color darkBodyWarm = Color(0xFFC8AC8D);

  static const Color darkMuted = Color(0xFF8F7C68);

  /// 4.96:1 on [darkSurface] — the faintest rung that still clears WCAG AA.
  static const Color darkFaint = Color(0xFF8F7D6E);

  static const Color cardBgDark04 = Color.fromRGBO(250, 245, 236, 0.04);

  static const Color cardBgDark05 = Color.fromRGBO(250, 245, 236, 0.05);

  /// Card border, quietest. `rgba(250,245,236,.08)` — the dock's rim, where the shadow lifts.
  /// Same value as [rowDividerDark], kept SEPARATE: border and divider are two roles that move apart.
  static const Color cardBorderDark08 = Color.fromRGBO(250, 245, 236, 0.08);

  static const Color cardBorderDark09 = Color.fromRGBO(250, 245, 236, 0.09);

  static const Color cardBorderDark14 = Color.fromRGBO(250, 245, 236, 0.14);

  static const Color rowDividerDark = Color.fromRGBO(250, 245, 236, 0.08);

  static const Color goldTintFill10 = Color.fromRGBO(212, 160, 23, 0.10);

  static const Color goldTintFill14 = Color.fromRGBO(212, 160, 23, 0.14);

  static const Color cardBgDark045 = Color.fromRGBO(250, 245, 236, 0.045);

  static const Color cardBorderDark12 = Color.fromRGBO(250, 245, 236, 0.12);

  static const Color ivoryBorder22 = Color.fromRGBO(250, 245, 236, 0.22);

  static const Color ivoryText86 = Color.fromRGBO(250, 245, 236, 0.86);

  static const Color goldTintFill12 = Color.fromRGBO(212, 160, 23, 0.12);

  // Earn button surface, ported from Pakiza's `goldFillSoft` / `goldFillSoftBorder` / `controlLift`.
  // The GRADIENT is the "shimmer" in the reference art — a soft sheen, never a moving highlight.
  // Alphas and stops are Pakiza's; the gold is ARUL's [gold] — a palette is never shared (§0).

  /// Earn button fill, LIGHT — white falling to cream; the sheen is the STEP, so neither stop is gold.
  static const LinearGradient earnFillLight = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFFFF), Color(0xFFF8F0DC)],
  );

  static const LinearGradient earnFillDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.fromRGBO(212, 160, 23, 0.20),
      Color.fromRGBO(212, 160, 23, 0.08),
    ],
  );

  static const Color earnBorderLight = Color.fromRGBO(212, 160, 23, 0.38);
  static const Color earnBorderDark = Color.fromRGBO(212, 160, 23, 0.35);

  /// Barely-there lift under a LIGHT-theme header control, and null on dark.
  ///
  /// The app is otherwise FLAT by design.
  /// But pure white on a cream ground with only a rim reads as painted on, not raised.
  /// Pakiza's `controlLift`, struck from Arul's ink.
  static const List<BoxShadow> controlLift = [
    BoxShadow(
      color: Color.fromRGBO(43, 17, 22, 0.05),
      blurRadius: 6,
      offset: Offset(0, 2),
    ),
  ];

  static const Color goldTintFill13 = Color.fromRGBO(212, 160, 23, 0.13);

  static const Color goldBorder35 = Color.fromRGBO(212, 160, 23, 0.35);

  static const Color goldBorder45 = Color.fromRGBO(212, 160, 23, 0.45);

  static const Color goldBorder52 = Color.fromRGBO(212, 160, 23, 0.52);

  static const Color goldBorder50 = Color.fromRGBO(212, 160, 23, 0.50);

  static const Color goldBorder40 = Color.fromRGBO(212, 160, 23, 0.40);

  static const Color goldBorderSolid = gold;

  static const Color lightText = Color(0xFF2B1116);

  /// 6.74:1 on ivory (WCAG AA) — evening installs read this over glare.
  static const Color lightSecondary = Color(0xFF6A5142);

  static const Color lightBody = Color(0xFF6B5240);

  /// 5.00:1 on ivory — footers, counters and chevrons are text too, and owe AA.
  static const Color lightFaint = Color(0xFF7A6657);

  static const Color cardBgLight = Color(0xFFFFFFFF);

  static const Color cardBorderLight = Color.fromRGBO(122, 30, 51, 0.12);

  static const Color dividerLight = Color.fromRGBO(122, 30, 51, 0.10);

  static const Color maroonTintFill07 = Color.fromRGBO(122, 30, 51, 0.07);

  static const Color maroonTintFill08 = Color.fromRGBO(122, 30, 51, 0.08);

  static const Color maroonBorder18 = Color.fromRGBO(122, 30, 51, 0.18);

  /// Light-theme dock rim `rgba(122,30,51,.08)` — quieter than [cardBorderLight]; a shadow lifts it.
  static const Color maroonBorder08 = Color.fromRGBO(122, 30, 51, 0.08);

  /// The now-playing row's title on LIGHT, 5.57:1 on ivory — [gold] itself fails contrast there.
  /// Darkened for light only; dark stays on [gold].
  static const Color nowPlayingTitleLight = Color(0xFF7A5F0E);

  /// Gold TEXT or glyph ink on a LIGHT surface. `#7A5F0E`, 5.57:1 on ivory.
  ///
  /// Same value and cause as [nowPlayingTitleLight] — [gold] does not carry on ivory.
  /// A different ROLE though, so the two move independently: a row's state versus a control's label.
  /// Anything gold-on-light that is TYPE, not fill, reads this.
  static const Color goldInkLight = Color(0xFF7A5F0E);

  /// The dock's surface on DARK, `#1B1215` — a step warmer than [darkSurface].
  /// So the capsule separates from the feed behind it without a rim. Light uses [cardBgLight].
  static const Color dockFillDark = Color(0xFF1B1215);

  static const Color dockActiveFillLight = Color(0xFFF0DCAA);

  static const List<BoxShadow> dockShadowDark = [
    BoxShadow(
      offset: Offset(0, 16),
      blurRadius: 38,
      color: Color.fromRGBO(0, 0, 0, 0.6),
    ),
  ];

  static const List<BoxShadow> dockShadowLight = [
    BoxShadow(
      offset: Offset(0, 14),
      blurRadius: 34,
      color: Color.fromRGBO(43, 17, 22, 0.14),
    ),
  ];

  /// The gold halo around a now-playing row's pause button.
  ///
  /// The handoff asks for a 14px halo here and a second 20px one on the dock's active cell.
  /// On a phone those read as haze — a 20px gold blur on a near-black capsule fogs the tab's edge.
  /// Stacked with this one, the dark theme looked smeared.
  /// The dock's is GONE: its cell has fill and a rim, which is enough.
  /// This one is HALVED to a tight contact glow that still says "lit" without bleeding into the row.
  static const List<BoxShadow> nowPlayingButtonGlow = [
    BoxShadow(blurRadius: 8, color: Color.fromRGBO(212, 160, 23, 0.18)),
  ];

  // Scrims — Spec > Colors > Scrims; all `rgba(20,9,12,x)`.
  // `Color(0x0014090C)` is a TRANSPARENT darkSurface -> only alpha moves, and no grey fringe appears.

  static const Color _scrim0 = Color.fromRGBO(20, 9, 12, 0.0);

  static const LinearGradient feedTopScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // The spec is a plain two-stop `.62 → 0` -> no mid-stop, or the mid-range reads weaker.
    colors: [Color.fromRGBO(20, 9, 12, 0.62), _scrim0],
  );

  static const LinearGradient feedBottomScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    // Plain two-stop `.72 → 0` per spec (see note on [feedTopScrim]).
    colors: [Color.fromRGBO(20, 9, 12, 0.72), _scrim0],
  );

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

  /// Sign-in scrim, re-cut from the spec's 3-stop ramp, which put its darkness at the bottom edge.
  ///
  /// Nothing sits at the bottom now — the only free-floating chrome is the wordmark up top.
  /// Everything else lives on the silk panel, which carries its own ground and needs no help.
  /// So this ramp does two jobs: a ceiling dark enough for the wordmark, and a floor for the nav bar.
  /// The MIDDLE is left near-clear on purpose — that band is the artwork the user is signing in for.
  /// Do NOT strengthen the middle to "help" the panel; darkening the centre only costs the wallpaper.
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

  static const Color dialogOverlay = Color.fromRGBO(20, 9, 12, 0.60);

  static const LinearGradient silkDark = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.fromRGBO(122, 30, 51, 0.35),
      Color.fromRGBO(212, 160, 23, 0.10),
    ],
  );

  static const LinearGradient silkLight = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color.fromRGBO(122, 30, 51, 0.10),
      Color.fromRGBO(212, 160, 23, 0.10),
    ],
  );

  static const Color silkBorderDark = Color.fromRGBO(212, 160, 23, 0.30);

  static const Color silkBorderLight = maroonBorder18;

  static const LinearGradient sheetGradientDark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [darkSheetGradientTop, darkSheetSurface],
  );

  static const Color skeletonBase = darkSurface;
  static const Color skeletonHighlight = Color(0xFF2A1218);

  /// Fill for chrome on media with NO scrim under it — [darkSurface] at 80%.
  ///
  /// The scrims are tuned for chrome at the screen's EDGES, where a ramp reaches full strength.
  /// A panel floating mid-screen has no such luxury — the scrim is weakest there by design.
  /// So the panel carries its own ground: this under [silkDark] holds ivory at ~10:1 on a white frame.
  /// That is the bar `ArulScrims` sets.
  /// Same value as the legacy `ArulColors.mediaFillStrong` -> one role, one number, no drift.
  static const Color mediaFillStrong = Color(0xCC14090C);

  static const List<Shadow> overMediaShadow = [
    Shadow(offset: Offset(0, 1), blurRadius: 8, color: Color(0x99000000)),
  ];

  /// Shadow for the feed action-rail icons.
  ///
  /// A single [overMediaShadow] lets an ivory glyph wash out over pale wallpapers.
  /// This stacks a tight, near-opaque contact halo that hugs the glyph edge on light media.
  /// Under it, a broader soft spread keeps the glyph grounded over dark media.
  /// So the icon carries its own contrast on ANY background, with no chip breaking the rail.
  static const List<Shadow> railIconShadow = [
    Shadow(blurRadius: 3, color: Color(0xE6000000)),
    Shadow(offset: Offset(0, 1), blurRadius: 10, color: Color(0xB3000000)),
  ];

  /// **The over-media glass recipe** — a translucent ivory fill under a hairline of the same ivory.
  ///
  /// The app's language for a control that sits on someone's wallpaper and must not compete with it.
  /// Every such control reads these two tokens rather than spelling the rgba twice.
  /// They are the SAME object at two sizes -> a drift would read as two design systems on one card.
  static const Color overMediaGlassFill = Color.fromRGBO(250, 245, 236, 0.18);
  static const Color overMediaGlassBorder = Color.fromRGBO(250, 245, 236, 0.45);

  /// **Smoked** glass — the fill for chrome on RAW artwork, with no scrim to supply contrast.
  ///
  /// [overMediaGlassFill] cannot do this job and no tuning makes it: ivory is near-white.
  /// A near-white fill over a white marble temple is invisible at ANY alpha, whiter but not clearer.
  /// Chrome over an unknown background must be the DARK half, with ivory kept for glyph and rim.
  /// [darkSurface] at `.55` — the alpha `mediaFillStrong` was measured at.
  /// Dense enough to clear 3:1 for an ivory glyph over the brightest wallpaper in the catalog.
  /// Translucent enough that the artwork still reads through — a LENS, never a chip.
  /// On dark artwork it all but vanishes and the rim carries the shape, which is right.
  /// NOT a shadow: a shadow bleeds outside its object onto the wallpaper; this is contained by the disc.
  static const Color overMediaInkFill = Color.fromRGBO(20, 9, 12, 0.55);

  // Typography — Spec > Typography. UI is the system stack, `fontFamily` null.
  // The bundled 'Marcellus' serif is for the Latin wordmark, titles, numerals and hero headings ONLY.
  // NEVER a localized string.

  /// The bundled display-serif family. Latin-only; must NOT wrap Indic text.
  static const String serif = 'Marcellus';

  /// Splash wordmark "Arul". 54px, Marcellus, ls `.04em` (54 × .04 = 2.16).
  /// With no gopuram mark the type carries the splash alone -> the largest wordmark in the app.
  static const TextStyle wordmarkSplash = TextStyle(
    fontFamily: serif,
    fontSize: 54,
    height: 1.05,
    letterSpacing: 2.16,
    color: ivory,
  );

  /// Sign-in wordmark "Arul". 38px, Marcellus.
  /// The only brand element on the screen -> it takes the weight, still below the splash's.
  static const TextStyle wordmarkSignIn = TextStyle(
    fontFamily: serif,
    fontSize: 38,
    height: 1.1,
    letterSpacing: 1.52,
    color: ivory,
  );

  /// Tagline / eyebrow. 11px caps, gold, ls `.42em` (11 × .42 = 4.62), over an uppercased string.
  static const TextStyle tagline = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 4.62,
    color: gold,
  );

  static const TextStyle screenTitle = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    height: 1.15,
    letterSpacing: 0.3,
  );

  /// The title in a top-level tab's header band. 26px Marcellus, ls `.04em` (26 × .04 = 1.04).
  ///
  /// ONE size for all three tabs — they cross-fade, so a resizing title read as the screen jumping.
  /// Never tune it per screen: change it here and all three move together.
  /// 26 × 1.15 is 29.9, which still clears the 34 band -> the header did not grow with the type.
  /// That headroom runs out around 29 — past there the band grows, and a bigger band resizes the reel.
  static const TextStyle screenHeaderTitle = TextStyle(
    fontFamily: serif,
    fontSize: 26,
    height: 1.15,
    letterSpacing: 1.04,
  );

  /// The WORDMARK in the feed's header band — "Arul", 28px Marcellus, ls `.04em` (28 × .04 = 1.12).
  ///
  /// The ONE deliberate exception to "one size for all three tabs".
  /// The other tabs show a page TITLE; the feed shows the brand.
  /// A wordmark matching the labels around it read as a third tab name, not as the app's mark.
  /// A different kind of object -> its own token, never a per-screen override of [screenHeaderTitle].
  /// 28 is near the ceiling: `28 × 1.15 = 32.2` in a 34 band leaves 1.8, some spent on the drop.
  /// Past ~29 the line box exceeds the band and the Row overflows — grow the band first.
  static const TextStyle wordmarkHeader = TextStyle(
    fontFamily: serif,
    fontSize: 28,
    height: 1.15,
    letterSpacing: 1.12,
  );

  static const TextStyle heroHeading = TextStyle(
    fontFamily: serif,
    fontSize: 21,
    height: 1.2,
  );

  static const TextStyle priceNumeral = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    height: 1.15,
  );

  static const TextStyle sheetTitle = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle rowTitle = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );

  /// Row title with the list's optical tracking. 15px w500, ls `.005em` (15 × .005 = 0.075).
  /// For the ringtone row — a single ellipsised line needs air a two-line [rowTitle] block does not.
  static const TextStyle rowTitleTracked = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.075,
  );

  static const TextStyle rowSub = TextStyle(fontSize: 12.5, height: 1.35);

  /// Floating-dock label, inactive. 12px w500, ls `.2`.
  ///
  /// The TRACKING is the point — every other small label carries the theme's, and 0 read as a new face.
  /// 12, not the handoff's 12.5 -> three labels sit in their thirds without FittedBox shrinking them.
  /// That shrinking is what actually made the dock look off-family on a 360dp phone.
  static const TextStyle dockLabel = TextStyle(
    fontSize: 12,
    height: 1.15,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );

  static const TextStyle dockLabelActive = TextStyle(
    fontSize: 12,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );

  static const TextStyle body = TextStyle(fontSize: 13.5, height: 1.5);

  static const TextStyle caption = TextStyle(fontSize: 12, height: 1.4);

  static const TextStyle chip = TextStyle(
    fontSize: 13.5,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w500,
  );

  static const TextStyle chipActive = TextStyle(
    fontSize: 13.5,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.w600,
  );

  // Why the chip styles pin `height` and `leadingDistribution`, where the rest of the file does not.
  //
  // A `Text` merges into the ambient `bodyMedium`, and ours carries `height: 1.45`.
  // So a chip label with no height got a 19.6px line box for 13.5px of type.
  // Flutter's DEFAULT leading distribution is proportional -> ~79% of that slack goes above baseline.
  // Centring that box centres the SLACK, not the letters -> labels sat ~2.7px low in a 34px pill.
  // `height: 1` makes the box the type, and `even` splits what is left equally.
  // Anything centring one of these styles in its own box then gets it right for free.
  // A control that SIZES to the label measures ~6px shorter — why the surface chip's padding was re-cut.

  /// Button label. 15px w600 from the spec's 15–16 range; `.copyWith(fontSize: 16)` where asked.
  static const TextStyle button = TextStyle(
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  /// Card corner. spec range 18–22; chosen 20.
  static const double cardRadius = 20;

  static const double rowsCardRadius = 20;

  static const double sheetTopRadius = 24;

  static const double inputRadius = 14;

  static const double pillRadius = 999;

  static const double iconChipRadius = 12;

  /// List-row corner. 15 — tighter than [cardRadius]; a 66-tall row at 20 reads as a lozenge.
  static const double rowRadius = 15;

  static const double coverRadius = 13;

  static const double dockRadius = 26;

  static const double dockActiveTabRadius = 18;

  static const double screenPadding = 16;

  static const double contentGap = 16;

  static const double cardPadding16 = 16;

  static const double cardPadding20 = 20;

  // Top-level tab header band — ONE band for all three tabs; see [ArulScreenHeader].
  // These ARE the feed's existing metrics -> changing them MOVES the reel.
  // The card geometry is solved from the height left below the band.

  static const double headerTopPadding = 6;

  static const double headerBottomPadding = 8;

  /// The height of the band, and of every control in it. 34.
  ///
  /// The handoff draws the Earn button at the SAME height as the category chips under it, which is 34.
  /// It is also the ONE number the reel's card geometry is solved against.
  /// So this is the value that keeps the card its designed size.
  static const double headerControlSize = 34;

  /// Header control corner. 14 — Pakiza's `AppRadius.headerButton`.
  /// NOT [pillRadius]: a rounded rectangle, not a capsule, is most of why it reads as a button.
  static const double headerButtonRadius = 14;

  static const double chipsBottomGap = 20;

  /// The air ABOVE the chip row, on top of [headerBottomPadding].
  ///
  /// 8 above against 33 below left the row riding high in its own band.
  /// These now resolve to the same gap either side — `headerBottomPadding + this == chipsBottomGap`.
  /// The pair sums to what the lopsided pair summed to -> the reel did not resize on recentring.
  static const double chipsTopGap = chipsBottomGap - headerBottomPadding;

  static const double ctaHeight50 = 50;

  static const double ctaHeight52 = 52;

  static const double ctaHeight54 = 54;

  static const double signInPillHeight = 56;

  static const double dialogButtonHeight = minHitTarget;

  /// Minimum interactive hit target. 48.
  ///
  /// Android's number, not iOS's 44 — Material's `MaterialTapTargetSize.padded`, the Accessibility
  /// Scanner's "touch target" check and WCAG 2.2 AA (2.5.8) all measure against 48. Every custom
  /// tappable in this app is built from this one constant, so the VISUALS never moved when it rose:
  /// each site centres its own drawn size inside the box and only the transparent hit area grew.
  /// Where a gap is drawn NEXT to one of these boxes it must be written as `gap - slack`, never as
  /// a literal, or the box's growth eats the gap — `RingtoneRow.controlGap` is the worked example.
  static const double minHitTarget = 48;

  // Floating dock geometry — constraints in docs/ui-direction.md §Dock; these values are the record.
  // The dock OVERLAYS the branch content -> these are also what a scrolling list must clear.

  static const double dockHeight = 78;

  static const double dockSideInset = 18;

  static const double dockBottomInset = 14;

  static const double dockInnerPadding = 10;

  static const double dockTabHeight = 58;

  static const double dockIconSize = 22;

  static const double dockTabGap = 6;

  /// Bottom padding a scrollable owes the dock, so its last item stays reachable.
  /// 120 — the handoff's number, comfortably clear of [dockHeight] + [dockBottomInset].
  static const double listBottomInsetUnderDock = 120;

  /// How opaque the fade behind the dock becomes. `.95`, not 1 -> a hairline of content shows through.
  /// That reads as depth rather than as a pasted-on bar.
  static const double dockScrimAlpha = 0.95;

  /// Where the fade reaches full strength, as a fraction of its height.
  /// `.42` — content dissolves on the way in instead of meeting a hard edge.
  static const double dockScrimStop = 0.42;

  static const double iconChipSize = 40;

  static const double iconChipIconSize = 21;

  static const double grabberWidth = 44;
  static const double grabberHeight = 4;
  static const double grabberRadius = 2;
  static const Color grabberColorDark = Color.fromRGBO(250, 245, 236, 0.25);
  static const Color grabberColorLight = Color.fromRGBO(43, 17, 22, 0.20);

  // Motion — Spec > Motion. Transform and opacity ONLY: never blur, never ShaderMask.

  static const Duration chromeRecedeOut = Duration(milliseconds: 150);

  static const Duration chromeSettleIn = Duration(milliseconds: 250);

  static const Duration sheetEnter = Duration(milliseconds: 300);

  static const Duration dialogEnter = Duration(milliseconds: 250);

  static const Duration skeletonLoop = Duration(milliseconds: 1800);

  static const Duration hairlineLoop = Duration(milliseconds: 1600);

  /// Cross-fade between dock branches. 200ms — a dissolve rather than a cut, still instant.
  static const Duration tabSwitch = Duration(milliseconds: 200);

  static const Duration diyaFlicker = Duration(milliseconds: 1100);

  static const Curve settleCurve = Curves.easeOut;

  static const Curve sheetCurve = Curves.ease;

  static const Curve loopCurve = Curves.linear;

  static const double hairlineWidth = 120;
  static const double hairlineHeight = 2;

  // Premium paywall — a SELF-CONTAINED visual system for the one route that sells the product.
  // That is why every token below carries the `paywall` prefix instead of joining the ladders above.
  // It does NOT reuse the app palette and must never be "harmonised" into it.
  // Its maroon is #7A1F23, a different ink from [maroon], and its creams sit warmer than [ivory].
  // Two paywall screens share one shell -> a value changed here moves both, which is the point.
  // The route is pinned LIGHT and English-only -> these are absolute colours with no dark counterpart.

  static const Color paywallMaroon = Color(0xFF7A1F23);

  static const LinearGradient paywallCtaFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF8A2427), Color(0xFF6B191C)],
  );

  static const Color paywallGold500 = Color(0xFFE8B34B);

  static const Color paywallGold600 = Color(0xFFD9A544);

  static const Color paywallGold700 = Color(0xFFC8933A);

  /// Clears AA on [paywallCream] — the PREMIUM eyebrow is small caps text, not ornament.
  static const Color paywallGoldDeep = Color(0xFF8A6218);

  static const Color paywallGoldSoft = Color(0xFFE0C58A);

  /// Header block ground `#FAF5E9` — a half-step warmer than [paywallCream], separating without a rule.
  static const Color paywallHeaderBg = Color(0xFFFAF5E9);

  static const Color paywallCream = Color(0xFFFDF8EC);

  static const LinearGradient paywallPanelFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFFFFDF6), Color(0xFFFBF4E2)],
  );

  static const Color paywallMedallionFill = Color(0xFFFBF1DA);

  static const Color paywallInk = Color(0xFF4A3524);

  static const Color paywallInkSecondary = Color(0xFF6B5A41);

  /// Muted ink — the fine print under the price, and the UPI caret. `#7D684D`.
  ///
  /// Darkened from `#8B7355` (4.09:1 on [paywallPanelFill]'s foot) to clear WCAG AA. The rung sits
  /// barely above [paywallInkFaint] because AA leaves no room between them on a cream ground.
  static const Color paywallInkMuted = Color(0xFF7D684D);

  /// Faint ink — the struck-through price and the reassurance line. `#7D6E50`.
  ///
  /// Darkened from `#A3926F` (2.77:1) — a struck price is still the price, and the reassurance line
  /// is body copy; both owe AA. It stays the LIGHTEST readable rung, not a decorative one.
  static const Color paywallInkFaint = Color(0xFF7D6E50);

  /// Clears AA on [paywallCream] — PER MONTH and the tagline are read, not decoration.
  static const Color paywallInkGold = Color(0xFF85632D);

  static const Color paywallInkUpi = Color(0xFF2C2418);

  static const Color paywallOnCta = Color(0xFFFBF3DE);

  static const Color paywallOnBadge = Color(0xFFF6E7C8);

  static const Color paywallBorderSoft = Color(0xFFE6D9BD);
  static const Color paywallBorderControl = Color(0xFFD9C9A5);

  static const Color paywallBorderPill = Color(0xFFE0D4B4);

  /// The white fill of the paywall's pills (social proof, the UPI chip) — pure white, not the
  /// cream, so they lift off [paywallCream].
  static const Color paywallPillFill = Color(0xFFFFFFFF);

  /// The mute disc over the onboarding clip. `rgba(46,29,20,.70)` — dark enough on any frame.
  static const Color paywallMuteFill = Color(0xB32E1D14);

  static const LinearGradient paywallBrandRule = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x00C8933A), paywallGold700],
  );

  static const LinearGradient paywallHeaderHairline = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0x00D9A544), paywallGold600, Color(0x00D9A544)],
  );

  static const LinearGradient paywallFeatureDivider = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00D9A544), Color(0x66D9A544), Color(0x00D9A544)],
  );

  static const List<BoxShadow> paywallCtaShadow = [
    BoxShadow(
      offset: Offset(0, 6),
      blurRadius: 18,
      color: Color.fromRGBO(107, 25, 28, 0.35),
    ),
  ];

  /// The CTA's top lip — the handoff's `inset 0 1px 0 rgba(255,255,255,.15)`.
  /// Flutter has no inset box-shadow -> drawn as a foreground gradient instead.
  /// White fading out by 4% of the pill's height; it is what stops the CTA reading as flat.
  /// So the STOPS are as load-bearing as the colour.
  static const LinearGradient paywallCtaTopLip = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x26FFFFFF), Color(0x00FFFFFF)],
    stops: [0.0, 0.04],
  );

  // Premium paywall typography — three BUNDLED, paywall-only families.
  // Cinzel for display, Lora for everything else, Gelasio for the price numerals.
  // Tracking is quoted in `em` by the handoff and pre-multiplied here, as everywhere above.
  // Lora has no U+20B9 -> every Lora style carries Gelasio in [paywallSerifFallback].
  // Otherwise "₹199" in the fine print pulls a Roboto rupee into a serif sentence.

  static const String paywallDisplayFamily = 'Cinzel';

  static const String paywallTextFamily = 'Lora';

  static const String paywallNumeralFamily = 'Gelasio';

  static const List<String> paywallSerifFallback = [paywallNumeralFamily];

  /// The Indic form of a letter-spaced display style.
  ///
  /// The FACE needs no handling: Flutter falls back per GLYPH, so a Tamil run inside a Cinzel or
  /// Lora style already lands on the system stack — which covers all five scripts at zero bundled
  /// bytes, exactly as Marcellus does for the rest of the app. The bundled Latin subsets are never
  /// asked for a glyph they do not carry.
  ///
  /// The TRACK is what cannot survive. Letter-spacing is a Latin small-caps device; Indic scripts
  /// have no case to spell in caps, and spacing their glyphs pulls a combining mark visually off
  /// the consonant it belongs to. Call sites that hand back Cinzel's TRAILING track as left padding
  /// must drop that padding in the same breath, or the label sits off-centre with nothing to centre.
  static TextStyle paywallUntracked(TextStyle latin) =>
      latin.copyWith(letterSpacing: 0);

  /// Nav title "SUBSCRIPTION". Cinzel 500 15px, ls `.18em` (15 × .18 = 2.7), over uppercased text.
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
  /// The tracking is TRAILING as well as leading -> the word sits ~5px right of true centre.
  /// The eyebrow's padding in the paywall view trims that back.
  static const TextStyle paywallEyebrow = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    height: 1.2,
    letterSpacing: 5.46,
    color: paywallGoldDeep,
  );

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

  static const TextStyle paywallPill = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 13,
    height: 1.3,
    color: paywallInkSecondary,
  );

  /// "PER MONTH". Lora 500 14px, ls `.28em` (14 × .28 = 3.92), uppercased at the call site.
  /// The trailing track is trimmed the same way as the eyebrow's.
  static const TextStyle paywallPriceCaption = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.2,
    letterSpacing: 3.92,
    color: paywallInkGold,
  );

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
  /// Both strings it carries are contractually FIXED — they state what the mandate charges.
  static const TextStyle paywallFinePrint = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12.5,
    height: 1.4,
    color: paywallInkMuted,
  );

  static const TextStyle paywallFeatureLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 13,
    height: 1.35,
    color: paywallInk,
  );

  static const TextStyle paywallUpiLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 1.2,
    color: paywallInkSecondary,
  );

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

  static const TextStyle paywallReassurance = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12,
    height: 1.35,
    color: paywallInkFaint,
  );

  static const double paywallRupeeSize = 40;

  static const double paywallAmountSize = 56;

  static const double paywallPriceGap = 4;

  static const double paywallBackSize = 34;

  static const double paywallBrandRuleWidth = 56;
  static const double paywallBrandRuleGap = 12;

  static const double paywallHairlineInset = 32;

  static const double paywallPanelInset = 28;
  static const double paywallPanelTopGap = 26;

  /// The cream ring inside the shrine frame and the gold rule inside that.
  /// The handoff's two inset box-shadows, drawn as nested borders.
  static const double paywallPanelRingWidth = 4;

  static const double paywallBracketSize = 14;
  static const double paywallBracketStroke = 2;
  static const double paywallBracketOffset = 6;

  static const double paywallPriceDividerWidth = 44;
  static const double paywallPriceDividerHeight = 2;

  /// Feature medallion — a 48px ring at 1.5px around a 20px line icon drawn at 1.8px.
  /// The handoff's own SVG stroke, kept because a Material glyph reads heavier than its frame.
  static const double paywallMedallionSize = 48;
  static const double paywallMedallionBorder = 1.5;
  static const double paywallFeatureIconSize = 20;
  static const double paywallFeatureIconStroke = 1.8;

  static const double paywallCtaPadding = 16;

  /// Press feedback: 0.98 for 120ms, ease-out (the handoff's own figures).
  static const double paywallPressScale = 0.98;
  static const Duration paywallPress = Duration(milliseconds: 120);

  static const double paywallOrnamentAlpha = 0.10;

  static const double paywallOrnamentRuleThickness = 1;

  static const Color paywallDottedGold = Color(0x99D9A544);

  static const double paywallNavOrnamentRuleWidth = 20;

  static const double paywallNavFloretSize = 8;

  static const double paywallNavOrnamentGap = 4;

  static const double paywallNavTitleOrnamentGap = 8;

  static const double paywallTempleDividerInset = 32;

  static const double paywallTempleDividerGopuramSize = 34;

  static const double paywallTempleDividerFloretSize = 8;

  static const double paywallTempleDividerGap = 8;

  static const double paywallTempleDividerTopGap = 20;

  static const double paywallTempleDividerBottomGap = 28;

  static const double paywallBrandOrnamentRuleWidth = 36;

  static const double paywallBrandFloretSize = 9;

  static const double paywallBrandFloretGap = 5;

  static const double paywallTaglineLotusSize = 15;

  static const double paywallTaglineOrnamentGap = 8;

  static const double paywallPanelChamfer = 14;

  static const double paywallPanelInnerInset = 5;

  static const double paywallPanelInnerChamfer = 10;

  static const double paywallPanelFrameStroke = 1;

  static const double paywallPanelContentInset = 21;

  static const double paywallPanelContentBottom = 17;

  static const double paywallPanelCrownSize = 34;

  static const double paywallPanelCrownRise = 13;

  static const double paywallPanelCrownInset = 42;

  static const double paywallPanelCrownGap = 7;

  static const double paywallPanelCrownBackdrop = 5;

  static const double paywallDottedDash = 2;

  static const double paywallDottedGap = 4;

  static const double paywallPriceOrnamentWidth = 48;

  static const double paywallPriceCaptionRuleWidth = 28;

  static const double paywallPriceCaptionRuleGap = 8;

  static const double paywallFeatureArtSize = 32;

  static const double paywallCtaFloretSize = 20;

  static const double paywallCtaOrnamentInset = 16;

  /// Air between a floret and the CTA label. Only a long label ever reaches it — English stops
  /// well short — but a Tamil label scaled to fit lands EXACTLY on the padding edge, and touching
  /// the ornament reads as a collision rather than a tight fit.
  static const double paywallCtaLabelGap = 10;

  static const double paywallCtaLotusSize = 32;

  static const double paywallCtaLotusRise = 16;

  static const double paywallFooterLotusSize = 10;

  static const double paywallFooterLotusGap = 4;

  static const double paywallFooterRuleWidth = 128;

  static const double paywallFooterRuleGap = 6;

  static const double paywallFooterBottomPadding = 8;

  static const double paywallBrandTaglineGap = 24;

  static const double paywallBrandBottomPadding = 13;

  /// Height the ₹2 lockup is scaled into on a short screen, where the clip must stay on screen.
  /// A UNIFORM scale, so PriceLockup's per-glyph ink centring survives it.
  static const double paywallDensePriceHeight = 46;

  static const double paywallTrialLeadGap = 2;

  static const double paywallTrialPriceGap = 4;

  static const double paywallTrialBadgeVerticalPadding = 3;

  static const double paywallPriceDividerTopGap = 10;

  static const double paywallPriceDividerBottomGap = 4;

  static const TextStyle premiumMemberNavTitle = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 25,
    height: 1.15,
    color: paywallMaroon,
  );

  static const TextStyle premiumMemberHeadline = TextStyle(
    fontFamily: paywallDisplayFamily,
    fontWeight: FontWeight.w500,
    fontSize: 25,
    height: 1.18,
    color: paywallMaroon,
  );

  static const TextStyle premiumMemberBody = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 15,
    height: 1.5,
    color: paywallInkSecondary,
  );

  static const TextStyle premiumMemberBillingLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 15,
    height: 1.3,
    color: paywallInkSecondary,
  );

  static const TextStyle premiumMemberBillingValue = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.3,
    color: paywallMaroon,
  );

  static const TextStyle premiumMemberReminder = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12.5,
    height: 1.35,
    color: paywallInkSecondary,
  );

  static const TextStyle premiumMemberCancelLabel = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.2,
    color: paywallMaroon,
  );

  static const TextStyle premiumMemberFootnote = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12,
    height: 1.5,
    color: paywallInkMuted,
  );

  static const TextStyle premiumMemberStatus = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: 0.5,
    color: ctaGreen,
  );

  static const double premiumMemberPageInset = 20;

  static const double premiumMemberNavTop = 12;

  static const double premiumMemberNavBottom = 10;

  static const double premiumMemberNavGap = 10;

  static const double premiumMemberBackRingSize = 34;

  static const double premiumMemberControlStroke = 1;

  static const double premiumMemberBackIconSize = 21;

  static const double premiumMemberScrollBottom = 24;

  static const double premiumMemberCardRadius = 20;

  static const double premiumMemberHeroHorizontal = 16;

  static const double premiumMemberHeroVertical = 18;

  static const double premiumMemberHeroGopuramSize = 64;

  static const double premiumMemberHeroRuleWidth = 34;

  static const double premiumMemberHeroFloretSize = 8;

  static const double premiumMemberHeroOrnamentGap = 8;

  static const double premiumMemberHeadlineGap = 10;

  static const double premiumMemberSublineGap = 7;

  static const double premiumMemberStatusGap = 14;

  static const double premiumMemberStatusHorizontal = 13;

  static const double premiumMemberStatusVertical = 6;

  static const double premiumMemberStatusFillAlpha = 0.14;

  static const double premiumMemberStatusBorderAlpha = 0.45;

  static const double premiumMemberSectionGap = 14;

  static const double premiumMemberRowHorizontal = 16;

  static const double premiumMemberRowVertical = 14;

  static const double premiumMemberRowFloretSize = 8;

  static const double premiumMemberRowLabelGap = 11;

  static const double premiumMemberReminderTop = 14;

  static const double premiumMemberReminderLotusSize = 15;

  static const double premiumMemberReminderGap = 8;

  static const double premiumMemberCancelTop = 18;

  static const double premiumMemberCancelHeight = 52;

  static const double premiumMemberCancelFloretSize = 20;

  static const double premiumMemberCancelFloretInset = 16;

  static const double premiumMemberCancelFillAlpha = 0.045;

  static const double premiumMemberCancelPressedAlpha = 0.10;

  static const double premiumMemberCancelBorderAlpha = 0.75;

  static const double premiumMemberDisabledAlpha = 0.6;

  static const double premiumMemberProgressSize = 20;

  static const double premiumMemberProgressStroke = 2;

  static const double premiumMemberFootnoteTop = 14;

  static const double premiumMemberFootnoteInset = 18;

  static const double premiumMemberFooterTop = 16;

  static const double premiumMemberFooterRuleWidth = 72;

  static const double premiumMemberFooterGopuramSize = 34;

  static const double premiumMemberFooterFloretSize = 8;

  static const double premiumMemberFooterGap = 7;

  static const TextStyle premiumResubscribeStatus = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 12,
    height: 1.2,
    letterSpacing: 0.7,
    color: paywallGoldDeep,
  );

  static const TextStyle premiumResubscribePayUsing = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w500,
    fontSize: 15,
    height: 1.3,
    color: paywallInk,
  );

  static const TextStyle premiumResubscribeUpiName = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 15,
    height: 1.25,
    color: paywallInkUpi,
  );

  static const TextStyle premiumResubscribeChange = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontWeight: FontWeight.w600,
    fontSize: 13,
    height: 1.2,
    color: paywallMaroon,
  );

  static const TextStyle premiumResubscribeFootnote = TextStyle(
    fontFamily: paywallTextFamily,
    fontFamilyFallback: paywallSerifFallback,
    fontSize: 12.5,
    height: 1.5,
    color: paywallInkMuted,
  );

  static const double premiumResubscribeStatusFillAlpha = 0.06;

  static const double premiumResubscribeStatusFloretSize = 12;

  static const double premiumResubscribeStatusFloretGap = 10;

  static const double premiumResubscribePayUsingTop = 18;

  static const double premiumResubscribePayUsingGap = 8;

  static const double premiumResubscribeUpiHorizontal = 14;

  static const double premiumResubscribeUpiVertical = 11;

  static const double premiumResubscribeUpiRadius = 16;

  static const double premiumResubscribeUpiIconSize = 32;

  static const double premiumResubscribeUpiIconRadius = 8;

  static const double premiumResubscribeUpiIconGap = 12;

  static const double premiumResubscribeChangeGap = 3;

  static const double premiumResubscribeChevronSize = 20;

  static const double premiumResubscribeCtaTop = 18;

  static const double premiumResubscribeCtaLotusClearance = 13;

  static const double premiumResubscribeFootnoteTop = 12;

  static const double premiumResubscribeFootnoteInset = 18;

  static const TextStyle premiumCelebrateTitle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: paywallMaroon,
  );

  static const TextStyle premiumCelebrateBody = TextStyle(
    fontSize: 14,
    height: 1.5,
    color: paywallInkSecondary,
  );

  static const TextStyle premiumCelebrateCta = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: paywallOnCta,
  );

  static const TextStyle premiumCelebrateDismiss = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: paywallMaroon,
  );

  static const double premiumCelebrateHorizontal = 20;

  static const double premiumCelebrateTop = 2;

  static const double premiumCelebrateBottom = 18;

  static const double premiumCelebrateGopuramSize = 42;

  static const double premiumCelebrateRuleWidth = 28;

  static const double premiumCelebrateFloretSize = 8;

  static const double premiumCelebrateOrnamentGap = 7;

  static const double premiumCelebrateTitleTop = 10;

  static const double premiumCelebrateBodyTop = 8;

  static const double premiumCelebrateRuleTop = 14;

  static const double premiumCelebrateRuleWidthFull = 96;

  static const double premiumCelebrateCtaTop = 14;

  static const double premiumCelebrateLotusClearance = 12;

  static const double premiumCelebrateDismissTop = 6;
}
