# UI direction

Read before touching `lib/theme`, `lib/app/theme`, `lib/app/widgets` or `lib/app/shell`. Change the
tokens, not the screens. Every regression contract in [edge-cases.md](edge-cases.md) binds regardless of
design. The feed stays a **vertical Shorts-style pager** — the native video pipeline is built around it,
so changing the paradigm means rebuilding the video layer.

## Palette

Read colours by role from **`lib/theme/arul_tokens.dart`** — never dynamic colour. `lib/app/theme/tokens.dart`
is the legacy ladder whose `rose*`/`teal*` NAMES survive with the new values behind them; there is no
teal. Light and dark are both required, and the choice is persisted. The green CTA is a proven
affordance — keep it.

## Chrome rules paid for on device

- One header band per tab (`ArulScreenHeader`): **48 tall to the finger, 34 to the eye** — the air lives
  inside the band (`bandHeight`/`bandPadding`), so an action spans it as a real target while drawing its
  34 px pill (42 was tried and reverted). The Marcellus title takes a +3 optical left inset and SHRINKS
  before it clips — never re-add an ellipsis (it cut a Malayalam title at 320 dp/1.3). Never tune title
  size per screen: tabs cross-fade, and per-screen sizes read as the screen jumping. The band's height is
  what the reel card is solved against ([feed-card.md](feed-card.md)).
- `ArulChipVariant.category` is the browse chip on both tabs; `.surface` is the Upload FORM chip. No rule
  under the chips.
- **Every custom tappable is built from `ArulTokens.minHitTarget` = 48** (Android's number, not iOS's
  44); the DRAWN size never changes — each control centres its visual in the box. A gap beside one is
  written `gap - slack`, never a literal, or raising the target eats it (`RingtoneRow.controlGap`). Lay
  the slack OUT, never `Transform` it — a transform paints outside its own hit bounds. Icon-only controls
  are `ArulIconTap`.
- **Every tap answers on press-DOWN**: a pressed visual and an `ArulHaptics` beat weighted to the action
  (`selection` picks, `tap` buttons, `firm` commits, `heavy` takes something away). Durations and curves
  come from `Motion` or `ArulTokens`; a widget never spells a `Duration` literal.
- **Settings lives in the dock, never the header.**
- The wordmark is the literal `Arul` in Marcellus. அருள் = grace / divine blessing — it does NOT mean
  "the South" (the working title); never gloss it so. Copy tone: warm, festive, plain — no religious
  salutations.

## Type

Base: Roboto (system). Display and wordmark: **Marcellus**, BUNDLED and wired in
`lib/app/theme/typography.dart`. Every string must render in Tamil, Telugu, Kannada and Malayalam, so the
serif is confined to display/headline plus the Latin wordmark. It reaches ONE localized string — the
header title — safely: **Marcellus has no Indic glyphs**, so those titles resolve per glyph through Noto
at the same size and tracking. Never add a second header style to "fix" it; watch for ascender clipping.

**`/premium` is the ONE screen off this stack**: Cinzel/Lora/Gelasio, bundled, instanced and subset by
`tools/build-fonts.py`, styled from the `paywall*` tokens. **No bundled serif carries U+20B9 ₹ except
Gelasio**, so every paywall Lora style names Gelasio in `fontFamilyFallback`, or a bare ₹ drops to Roboto
mid-sentence. Gelasio sets OLD-STYLE figures, so an amount's ink centre MOVES with its digits — centring
the ₹ is a per-price calculation off the glyph table (`PriceLockup`, pixel-asserted), never `Row` +
`center`, which centres BOXES.

## Drawn art is ARTWORK, not chrome

The ringtone tile's grounds and gold ink live in `ringtone_tile.dart` and **must not become tokens** —
tokens describe chrome, not pictures; the same holds for every CustomPainter motif. Bundled deity art is
lossless WebP, inked a shade paler than the tile because it sits ON a ground. A glyph the icon set lacks
is PAINTED (`arul_line_icons.dart`), never an emoji — budget Android 8–10 ROMs draw one as tofu. The
red/gold static splash art was REJECTED by the owner. The lotus video is retired too (owner): the splash
and the wall show the region's deity, Murugan by default.

## Dock

- Geometry and colour come from the `dock*` tokens. **No blur** and **no glow on the active cell** — a
  gold halo fogged the cell's edge on a real panel; fill plus rim is enough.
- A scrollable under the dock owes `AppShell.dockClearance(context)` of bottom clearance. It returns **0
  when no `AppShell` sits above the caller**, which is what makes it safe to call unconditionally — a
  flat constant left dead space under Settings pushed as a route.
- **The scrim behind the capsule fades to the surface's own alpha-0, never `Colors.transparent`** — that
  is transparent BLACK, and lerping through it smears grey on the ivory theme.
- Labels shrink, never clip: a 1.1 text-scale clamp (`PaywallGround`'s 1.3 is the only other) plus
  `FittedBox(scaleDown)`, because a long Malayalam label at 2× bursts the fixed cells. Keep the theme's
  own tracking — at 0 the labels read as a different typeface.
- Leaving Wallpapers releases the decoders, leaving Ringtones stops the preview. All branches stay
  mounted (scroll positions survive), and `ArulBranchCrossfade` keeps `TickerMode` off for hidden ones.

## Perf rules that SHAPE the design

- **No glassmorphism, the dock included.** `BackdropFilter` costs ~6–9 ms of raster per frame on mid-tier
  Android — the budget the video decoder needs. Legibility comes from gradient scrims
  (`feedTopScrim`/`feedBottomScrim`, two-stop on purpose).
- **No `shimmer` package, no `ShaderMask`** — a mask forces `saveLayer()`, an offscreen pass per frame.
  Slide a gradient FILL instead. Reach for a gradient before motion, and for motion before a mask; a
  mask, never.
- **No `google_fonts`, no `font_awesome_flutter`** — runtime font fetching and whole icon fonts. The
  system stack renders Latin plus all five Indic scripts free, and built-in `Icons` tree-shake. Bundling
  in-APK is the only way to add a face.
- Feed pages get no keep-alive and no extra `RepaintBoundary` (`PageView.builder` adds one). Images
  decode at display size and the image cache is capped in `main.dart` — a 1080×1920 wallpaper is ~8.3 MB
  of RGBA whatever its file size.
- **Device tier, not a boolean.** `DeviceQuality` resolves `low`/`mid`/`high` ONCE per process from
  `MainActivity.deviceTier()` and fails open to `mid`. `low` is exactly the poster rule
  ([launch-surface.md](launch-surface.md)) and nothing may widen it — the sign-in funnel is read against
  that population. Tier buys COST (decoder budget, image-cache ceiling, animation budget), never
  composition: **never branch layout on it.** `Build.SOC_MODEL` may cap a phone at `mid` and never
  creates a `low` (`mt68` is listed: an mt6878 is where the 48 MB image cache was measured failing).
- **One reduce-motion answer: `context.reduceMotion`** (`lib/app/theme/motion.dart`), true under Remove
  animations or on the `low` tier. Every animation in `lib/app/widgets/**` and `lib/features/**` routes
  through it. **Animations HOLD at their resting state, never vanish**: a sweep parks mid-gradient, a
  sheet opens at its settled offset, a press scale stays 1, a haptic still fires. Arm a repeating
  controller from `didChangeDependencies`, never a field initializer.
- **Material 3 Expressive is NOT in Flutter stable** (`material_ui` only copies the framework's Material
  code). Do not chase it: premium here = the brand system, Material's motion tokens and one spring on
  the CTA.

## Launcher icon

Masters are raster files OUTSIDE the repo. Regenerate the adaptive set with
`node tools/icon_from_png.mjs <icon.png>`. Anything left in `assets/images/` ships in the APK, so
never write a generator's output there.
