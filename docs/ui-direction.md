# UI Direction — Arul

> Describes SHIPPED code (`lib/app/theme`, `lib/app/widgets`, `lib/app/shell`). Change the tokens,
> not the screens.

**The UI/UX is Arul's own** — never clone Pakiza's look or sync a theme change (the one exception is
`ArulEarnButton`, CLAUDE.md §0). Logic/data layers, entitlement gating, and every contract in
[edge-cases.md](edge-cases.md) stay fixed regardless of design. The wallpaper feed remains a
**vertical Shorts-style pager** — the native video pipeline (player pool, prefetch, decoder budget)
is built around that paradigm; changing it = rebuilding the video layer.
Load the frontend-design skill when building screens. Tokenize every color — no literals in screens.

## Palette — THE source (never dynamic color; CLAUDE.md §7 points here, it does not restate)
Read these by role from **`lib/theme/arul_tokens.dart`**. `lib/app/theme/tokens.dart` is the legacy
ladder whose `rose*`/`teal*` NAMES survive with these values behind them — there is no teal anymore.
Light + dark themes are both required, and persisted.
| Token | Value | Use |
| --- | --- | --- |
| maroon (primary) | `#7A1E33` | brand seed, accents, active states |
| gold (accent) | `#D4A017` | highlights, premium badging, selection |
| ivory | `#FAF5EC` | light surfaces |
| darkSurface | `#14090C` | dark surfaces + splash (matches pubspec splash color) |
| ctaGreen | `#1FA75A` | primary CTA (proven affordance — keep) |

## Chrome rules paid for on device
- One header band per tab (`ArulScreenHeader`): **34px** control row — the Earn button must match the
  chip height under it (42 was tried and reverted) — and a **26px** Marcellus title with +3 optical
  left inset (equal padding does not LOOK equal against a curved rim). Don't tune title size per
  screen: tabs cross-fade, and per-screen sizes read as the whole screen jumping. The band's height is
  what the reel card geometry is solved against; moving it resizes the card.
- `ArulChipVariant.category` is the browse chip on both tabs; `.surface` is the Upload screen's FORM
  chip — a different thing. No rule under the chips; the row sits in equal air
  (`chipsTopGap`/`chipsBottomGap`).
- Settings lives in the dock, never the header. The feed's header gear is deliberately gone — a dock
  tab is the entry; do not put it back.
- The wordmark is the literal text `Arul` in Marcellus. அருள் = grace / divine blessing — it does NOT
  mean "the South" (that was Dakshin, the working title); never gloss it so. Copy tone: warm, festive,
  plain — no religious salutations.

## Type
Base: Roboto (system). Display/wordmark: **Marcellus**, BUNDLED at `assets/fonts/Marcellus-Regular.ttf`,
wired in `lib/app/theme/typography.dart` — never `google_fonts`, a banned dependency (§Perf). Every
locale string must render in Tamil/Telugu/Kannada/Malayalam, so `typography.dart` confines the serif to display/headline + Latin wordmark.
It reaches ONE localized string — `ArulScreenHeader`'s title — safely, not luckily: Marcellus has no Indic glyphs, so those titles resolve per-glyph through Noto at the same size and tracking. Do not add a second header style to "fix" it; watch for ascender clipping instead.
**`/premium` is the ONE screen off this stack**: Cinzel/Lora/Gelasio, bundled, instanced+subset by `tools/build-fonts.py`, styled from `ArulTokens.paywall*` (its member/resubscribe states from `premiumMember*`/`premiumResubscribe*`)
— safe only because that page is English-by-decision. **No bundled serif has U+20B9 ₹** (Marcellus/Cinzel/Lora all lack it), so a bare ₹ drops to
Roboto mid-sentence; Gelasio carries it and every paywall Lora style names it in `fontFamilyFallback`. Gelasio is Georgia's metric twin, so the price
gets OLD-STYLE figures (3/4/5/7/9 fall below the baseline) and an amount's ink centre MOVES with its digits — centring the ₹ is a per-price calc off the
glyph table (`PriceLockup`, pixel-asserted), never `Row`+`center`, which centres BOXES and leaves the rupee ~8px high, as the handoff's HTML does.

## Drawn art is ARTWORK, not chrome
The ringtone tile's ten grounds and `#EBD6A3` gold ink live in `ringtone_tile.dart` and must not become
tokens — tokens describe chrome, not pictures; same for every CustomPainter motif (kolam grids, gopuram
silhouette). The 17 bundled deity PNGs are inked in that SAME gold: change one, regenerate the other. A glyph the icon set lacks is PAINTED (`arul_line_icons.dart`) or
is an EMOJI off the system font (the Earn button's 🎁). The 2026-08 red/gold static splash art was
tried and REJECTED by the owner — splash + sign-in keep the lotus video
(`assets/video/splash.mp4`); don't re-propose a static art backdrop.

## Dock — `ArulNavDock` / `AppShell` (`lib/app/shell/app_shell.dart`)
- Geometry and colour come from `ArulTokens.dock*`, no literals. No blur (§Perf) and no glow on the
  active cell — a 20px gold halo fogged the cell's edge on a real panel; fill plus rim is enough.
- A scrollable under the dock owes `AppShell.dockClearance(context)` of bottom clearance. It returns
  **0 when no `AppShell` sits above the caller**, which is what makes it safe to call unconditionally
  — a flat 120 left dead space under Settings when pushed as a route. Applied on the Ringtones and
  Settings branches; Wallpapers' `FeedEmpty`/`FeedError` pad horizontally only and run under the dock.
- The scrim behind the capsule fades to the surface's own alpha-0, **never `Colors.transparent`** —
  that is transparent BLACK, and lerping through it smears grey on the ivory theme.
- Labels shrink, never clip: a 1.1 text-scale clamp (`PaywallGround`'s 1.3 is the only other) + `FittedBox(scaleDown)`, because
  "വാൾപേപ്പറുകൾ" at 2× bursts the fixed 58/78 cells. Keep the theme's own tracking — at 0 the labels
  read as a different typeface.
- Branch switches: leaving Wallpapers → `releaseDecoders()`, returning → `reclaimDecoders()`; leaving
  Ringtones → preview stop. All branches stay mounted (scroll positions survive);
  `ArulBranchCrossfade` keeps `TickerMode` off for hidden branches — its dartdoc in `app_shell.dart`
  is the reference.

## Perf rules that SHAPE the design (not optional polish)
- **No glassmorphism — and none on the nav dock either**, the one place a handoff asked for it.
  `BackdropFilter` costs ~6–9ms raster/frame on mid-tier Android and would eat the budget the video
  decoder needs. Chrome legibility comes from gradient scrims, ordinary paints — the SHIPPED pair is
  `ArulTokens.feedTopScrim`/`feedBottomScrim`, two-stop on purpose (`ArulScrims.top/bottom` is dead).
- **No `shimmer` package / no `ShaderMask`** — a mask forces `saveLayer()`, an offscreen pass per frame.
  Slide a gradient FILL instead (`skeleton.dart`): same look, zero cost. Note the Earn button's "shimmer"
  is not animated at all — a static vertical sheen (`earnFillLight`) plus `controlLift`. Reach for a
  gradient before motion, and for motion before a mask; a mask, never.
- **No `google_fonts`, no `font_awesome_flutter`** — runtime font fetching and whole icon fonts. The
  system stack renders Latin + all 5 Indic scripts free; built-in `Icons` tree-shake and stay the
  default. Marcellus is BUNDLED in-APK — the only allowed way to add a face.
- Feed pages get no keep-alive and no extra RepaintBoundary (PageView.builder adds one already). Images
  decode at display size (`memCacheWidth` × devicePixelRatio) and the image cache is capped in
  `main.dart` — a 1080×1920 wallpaper is ~8.3 MB of RGBA regardless of file size.
- **Material 3 Expressive is NOT in Flutter stable** (Material frozen at 3.44; M3E deferred to the
  decoupled `material_ui` package, 1.0.0 as of 2026-08). Do not chase it. Premium here = the brand system above +
  Material's real motion tokens (`Easing`, `Durations`) + one spring on the CTA.

## Launcher icon
Masters are RASTER files that live OUTSIDE the repo. Regenerate the adaptive set
(`mipmap-*/ic_launcher{,_foreground,_monochrome,_background}.png`, composed by
`mipmap-anydpi-v26/ic_launcher.xml`) with `node assets/brand/icon_from_png.mjs <icon.png> <splash.png>`
— it ALSO writes `assets/images/splash_bg.jpg`, which must be DELETED after every run: that art was
rejected (§Drawn art) and anything left in `assets/images/` ships in the APK.
