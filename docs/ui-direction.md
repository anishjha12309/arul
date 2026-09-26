# UI Direction — Arul

> Describes SHIPPED code (`lib/theme`, `lib/app/theme`, `lib/app/widgets`, `lib/app/shell`). Change
> the tokens, not the screens.

**The UI/UX is Arul's own** — never clone Pakiza's look or sync a theme change (the one exception is
`ArulEarnButton`, CLAUDE.md §0). Logic, data, entitlement gating and every regression contract in
[edge-cases.md](edge-cases.md) stay fixed regardless of design. The wallpaper feed remains a
**vertical Shorts-style pager** — the native video pipeline is built around that paradigm, so
changing it means rebuilding the video layer.

## Palette — THE source (never dynamic color)
Read these by role from **`lib/theme/arul_tokens.dart`**. `lib/app/theme/tokens.dart` is the legacy
ladder whose `rose*`/`teal*` NAMES survive with these values behind them — there is no teal any more.
Light and dark are both required, and the choice is persisted.

| Token | Value | Use |
| --- | --- | --- |
| maroon (primary) | `#7A1E33` | brand seed, accents, active states |
| gold (accent) | `#D4A017` | highlights, premium badging, selection |
| ivory | `#FAF5EC` | light surfaces |
| darkSurface | `#14090C` | dark surfaces + splash (matches the pubspec splash color) |
| ctaGreen | `#1FA75A` | primary CTA (proven affordance — keep) |

## Chrome rules paid for on device
- One header band per tab (`ArulScreenHeader`): **48 tall to the finger, 34 to the eye** — the
  air lives inside the band (`bandHeight`/`bandPadding`), so an action spans it as a real target
  while drawing its 34px pill where it always did (`ArulEarnButton`; 42 was tried and reverted). A
  **26px** Marcellus title with a +3 optical left inset (equal padding does not LOOK equal against
  a curved rim) that SHRINKS before it clips — never re-add an ellipsis, it cut a Malayalam title at
  320 dp/1.3. Don't tune title size per screen: tabs cross-fade, and per-screen sizes read as the
  whole screen jumping. The feed's wordmark is the one override, a different object class. The
  band's total height is what the reel card geometry is solved against, so moving it resizes the card.
- `ArulChipVariant.category` is the browse chip on both tabs; `.surface` is the Upload screen's FORM
  chip — a different thing. **No rule under the chips**; the row sits in equal air.
- **Every custom tappable is built from `ArulTokens.minHitTarget` = 48**, Android's number, not
  iOS's 44. The DRAWN size never changes with it — each control centres its visual (chip 34, transport 34, back ring 34, UPI pill 36) in
  the box and only transparent hit area grows. A gap drawn beside one of those boxes is written as
  `gap - slack`, never a literal, or raising the target eats the gap: `RingtoneRow.controlGap`.
  Lay the slack OUT, never `Transform` it — a transform paints slack outside its own hit bounds (the
  settings pencil takes its 14 px from the card padding). Icon-only controls are `ArulIconTap`.
- **Every tap answers on press-DOWN**: a pressed visual and an `ArulHaptics` beat weighted to the
  action — `selection` picks a value, `tap` a button, `firm` a commit (Apply, Set, Share), `heavy`
  takes something away (delete, cancel a subscription). Durations and curves come from `Motion`
  (`lib/app/theme/motion.dart`) or `ArulTokens`; a widget never spells a `Duration` literal.
- **Settings lives in the dock, never the header.** The feed's header gear is deliberately gone.
- The wordmark is the literal text `Arul` in Marcellus. அருள் = grace / divine blessing — it does NOT
  mean "the South" (that was the working title); never gloss it so. Copy tone: warm, festive, plain —
  no religious salutations.

## Type
Base: Roboto (system). Display/wordmark: **Marcellus**, BUNDLED and wired in
`lib/app/theme/typography.dart` — never `google_fonts`, a banned dependency (§Perf). Every locale
string must render in Tamil, Telugu, Kannada and Malayalam, so `typography.dart` confines the serif
to display/headline plus the Latin wordmark. It reaches ONE localized string — the screen header's
title — safely, not luckily: **Marcellus has no Indic glyphs**, so those titles resolve per-glyph
through Noto at the same size and tracking. Do not add a second header style to "fix" it; watch for
ascender clipping instead.

**`/premium` is the ONE screen off this stack**: Cinzel/Lora/Gelasio, bundled, instanced and subset
by `tools/build-fonts.py`, styled from the `paywall*` tokens; localized in all six, Indic resolving
per glyph through Noto like the header titles. **No bundled serif carries U+20B9 ₹ except Gelasio**, so a bare ₹ would drop to
Roboto mid-sentence; every paywall Lora style names Gelasio in `fontFamilyFallback`. Gelasio is
Georgia's metric twin, so the price gets OLD-STYLE figures and an amount's ink centre MOVES with its
digits — centring the ₹ is a per-price calculation off the glyph table (`PriceLockup`,
pixel-asserted), never `Row` + `center`, which centres BOXES.

## Drawn art is ARTWORK, not chrome
The ringtone tile's ten grounds and its `#EBD6A3` gold ink live in `ringtone_tile.dart` and **must
not become tokens** — tokens describe chrome, not pictures; the same holds for every CustomPainter
motif. The bundled deity art is lossless **WebP**, inked a shade paler than the tile because it sits
ON a ground. A glyph the icon set lacks is PAINTED (`arul_line_icons.dart`), never an emoji —
budget Android 8–10 ROMs draw one as tofu. The red/gold static splash art was REJECTED by the owner —
splash and sign-in keep the lotus video; don't re-propose it.

## Dock — `ArulNavDock` / `AppShell`
- Geometry and colour come from the `dock*` tokens, no literals. **No blur** (§Perf) and **no glow on
  the active cell** — a 20px gold halo fogged the cell's edge on a real panel; fill plus rim is
  enough.
- A scrollable under the dock owes `AppShell.dockClearance(context)` of bottom clearance. It returns
  **0 when no `AppShell` sits above the caller**, which is what makes it safe to call
  unconditionally — a flat constant left dead space under Settings when pushed as a route. Applied on
  the Ringtones and Settings branches; Wallpapers' empty and error states pad horizontally only and
  run under the dock.
- **The scrim behind the capsule fades to the surface's own alpha-0, never `Colors.transparent`** —
  that is transparent BLACK, and lerping through it smears grey on the ivory theme.
- Labels shrink, never clip (the header title and `CtaButton` labels follow the same rule): a 1.1
  text-scale clamp (`PaywallGround`'s 1.3 is the only other) plus
  `FittedBox(scaleDown)`, because a long Malayalam label at 2× bursts the fixed cells. Keep the
  theme's own tracking — at 0 the labels read as a different typeface.
- Branch switches: leaving Wallpapers releases the decoders, returning reclaims them; leaving
  Ringtones stops the preview. All branches stay mounted (scroll positions survive), and
  `ArulBranchCrossfade` keeps `TickerMode` off for hidden branches.

## Perf rules that SHAPE the design (not optional polish)
- **No glassmorphism — and none on the nav dock either**, the one place a handoff asked for it.
  `BackdropFilter` costs ~6–9 ms of raster per frame on mid-tier Android and would eat the budget the
  video decoder needs. Chrome legibility comes from gradient scrims and ordinary paints — the SHIPPED
  pair is `feedTopScrim`/`feedBottomScrim`, two-stop on purpose.
- **No `shimmer` package, no `ShaderMask`** — a mask forces `saveLayer()`, an offscreen pass per
  frame. Slide a gradient FILL instead: same look, zero cost. The Earn button's "shimmer" is not
  animated at all, just a static vertical sheen. Reach for a gradient before motion, and for motion
  before a mask; a mask, never.
- **No `google_fonts`, no `font_awesome_flutter`** — runtime font fetching and whole icon fonts. The
  system stack renders Latin plus all five Indic scripts free, and built-in `Icons` tree-shake.
  Marcellus is BUNDLED in-APK, the only allowed way to add a face.
- Feed pages get no keep-alive and no extra `RepaintBoundary` (`PageView.builder` adds one already).
  Images decode at display size and the image cache is capped in `main.dart` — a 1080×1920 wallpaper
  is ~8.3 MB of RGBA regardless of file size.
- **Device tier, not a boolean.** `DeviceQuality` resolves `low`/`mid`/`high` ONCE per process from
  the native table in `MainActivity.deviceTier()` and fails open to `mid`. `low` is exactly the
  shipped poster rule and nothing may widen it — that population is what the sign-in funnel is read
  against. Tier buys COST, never composition: decoder budget seed, image-cache ceiling, animation
  budget. **Never branch layout on it.** `Build.SOC_MODEL` may cap a phone at `mid` and can never
  create a `low`; `mt68` is on that list because an mt6878 is the phone the 48 MB cache was measured
  failing on (§Perf-measurement).
- **One reduce-motion answer: `context.reduceMotion`** (`lib/app/theme/motion.dart`), true when
  `MediaQuery.disableAnimations` is set — Remove animations (transition scale 0; Battery Saver
  does not set it on every ROM) — or the tier is `low`. Every animation in `lib/app/widgets/**` and `lib/features/**` routes through it.
  **Animations HOLD at their resting state, they are not removed**: a sweep parks mid-gradient rather
  than going flat, a sheet opens at its settled offset rather than at +24, a press scale stays at 1,
  a haptic still fires. Nothing changes position when the flag flips. Arm a repeating controller from
  `didChangeDependencies`, never a field initializer — the lookup needs an InheritedWidget.
- **Material 3 Expressive is NOT in Flutter stable** (`material_ui` only copies the framework's
  Material code). Do not chase it: premium here = the brand system, Material's real motion tokens
  (`Easing`, `Durations`) and one spring on the CTA.

## Launcher icon
Masters are RASTER files that live OUTSIDE the repo. Regenerate the adaptive set with
`node assets/brand/icon_from_png.mjs <icon.png> <splash.png>` — it ALSO writes
`assets/images/splash_bg.jpg`, which must be DELETED after every run: that art was rejected
(§Drawn art) and anything left in `assets/images/` ships in the APK.
