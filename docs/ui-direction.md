# UI Direction — Arul

> **BUILT 2026-07-14** — this describes shipped code (`lib/app/theme`, `lib/app/widgets`), not a
> proposal. Change the tokens, not the screens. Perf rules that shape the design are in §Perf.

**The UI/UX is Arul's own.** Screens, layout and navigation chrome are designed fresh — never clone
Pakiza's look, and never sync a theme change between the two. What stays FIXED regardless of design:
logic/data layers, entitlement gating, and every behavioral contract in docs/edge-cases.md. One
structural constant: the wallpaper feed remains a **vertical Shorts-style pager** — the whole native
video pipeline (player pool, prefetch, decoder budget) is built around that paradigm; changing it =
rebuilding the video layer.
Load the frontend-design skill when building screens. Tokenize every color — no literals in screens.

## Brand
- **Name:** Arul (அருள் — Tamil for *grace / divine blessing*). Wordmark `Arul`, tagline `SOUTH INDIAN
  WALLPAPERS`. It does NOT mean "the South" — that was Dakshin, the working title; never gloss it so.
- **Feel:** Kanjivaram silk + temple gold — rich, warm, **devotional**. The catalogue IS deity
  content: Amman, Ayyappan, Murugan, Perumal, Sivan + Temples. Design reverent, not kitsch: deep
  silks, gold, oil-lamp warmth; no cartoon deity clip-art chrome.
- **Browse = CATEGORY, always.** A chip row over the feed: All · Amman · Ayyappan · Murugan · Perumal ·
  Sivan · Temples (client-side filter on `category`). Static and live interleave inside every category
  — **never filter or tab by static/live**; type is a rendering detail. Both browse tabs render it with
  `ArulChipVariant.category` over `ArulTokens.chipsBottomGap` — one control, one look, one rhythm.
  `ArulChipVariant.surface` is the Upload screen's FORM chip, a different thing.

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

## Screen chrome
Every top-level tab wears ONE header band — `ArulScreenHeader`: 16 gutter, 6 above, 8 below, a **34px**
control row (`headerControlSize`; briefly 42 to match Pakiza and reverted — the Earn button must be the
height of the chips under it), title `screenHeaderTitle` (**26px** Marcellus, +3 optical left inset:
equal padding does not LOOK equal against the button's curved rim). The tabs once ran 24 / 27 / 22 at
three drops and, because they cross-fade, a title that resized between them read as the whole screen
jumping. Don't tune per screen — and the band's height is what the reel's card geometry is solved
against, so moving it resizes the card. Dock: [reference/nav-dock.md](reference/nav-dock.md).
**Both browse tabs carry ONE header action and it is the same object** — `ArulEarnButton`, a straight
port of **Pakiza's `EarnChip`** (radius 14, 12/16 padding, 🎁 emoji, 14px w700 label, 550ms wiggle —
all Pakiza's; the gold is ARUL's and the height is Arul's 34, see CLAUDE.md §0). Two hand-built
look-alikes drifted here first and never matched the art; do not rebuild it by eye. Settings is NOT
up here. No rule under the chips, and the chip row sits in equal air (`chipsTopGap`/`chipsBottomGap`).

## Type
Base: Roboto (system). Display/wordmark: **Marcellus**, BUNDLED at `assets/fonts/Marcellus-Regular.ttf`,
wired in `lib/app/theme/typography.dart:36` — never `google_fonts`, a banned dependency (§Perf). Every
locale string must render in Tamil/Telugu/Kannada/Malayalam, so the serif applies ONLY to the
display/headline tiers + Latin wordmark; all UI text uses the base stack (Noto fallbacks).

## Motifs
Sign-in + splash: **kolam dot-grid patterns** (line-drawn loops), a **gopuram silhouette** gradient at
the horizon, gold particle shimmer — CustomPainter + video-bg variant (new art, Pakiza's painter
architecture). Premium: silk gradient maroon→deep plum, gold zari strips, wallpaper-focused copy.
Ringtone rows: a **procedural kolam medallion** per track (`ringtone_medallion.dart`) — jewel-tone
ground, pulli ring, a deity emblem by category, a diya while previewing. Its ten grounds and `#EBD6A3`
gold ink are ARTWORK, live in that file, and must not become tokens — as for every drawn motif: tokens
describe chrome, not pictures.
The 2026-08 red/gold static splash art was tried and REJECTED by the owner (2026-08-03) — the
splash + sign-in keep the lotus video; don't re-propose a static art backdrop.

## Copy tone
English + 5 South Indian languages. Warm, festive, plain — no religious salutations. Share message
pattern: "Beautiful South Indian wallpapers — get Arul: <link>".

## Perf rules that SHAPE the design (not optional polish)
- **No glassmorphism — and none on the nav dock either**, the one place a handoff asked for it.
  `BackdropFilter` costs ~6–9ms raster/frame on mid-tier Android and would eat the budget the video
  decoder needs. Chrome legibility comes from gradient scrims (`ArulScrims.top/bottom`), ordinary
  paints; this is why the feed looks the way it does. Dock: [reference/nav-dock.md](reference/nav-dock.md).
- **No `shimmer` package / no `ShaderMask`** — a mask forces `saveLayer()`, an offscreen pass per frame.
  Slide a gradient FILL instead (`skeleton.dart`): same look, zero cost. Note the Earn button's "shimmer"
  is not animated at all — a static vertical sheen (`earnFillLight`) plus `controlLift`. Reach for a
  gradient before motion, and for motion before a mask; a mask, never.
- **No `google_fonts`, no `font_awesome_flutter`** — runtime font fetching and whole icon fonts. The
  system stack renders Latin + all 5 Indic scripts free; built-in `Icons` tree-shake and stay the
  default. Marcellus is BUNDLED in-APK — the only allowed way to add a face. A glyph the set lacks is
  PAINTED (`arul_line_icons.dart`) or, where the design wants full colour, is an EMOJI off the system
  font — that is the Earn button's 🎁, and it costs no asset either.
- Feed pages get no keep-alive and no extra RepaintBoundary (PageView.builder adds one already). Images
  decode at display size (`memCacheWidth` × devicePixelRatio) and the image cache is capped in
  `main.dart` — a 1080×1920 wallpaper is ~8.3 MB of RGBA regardless of file size.
- **Material 3 Expressive is NOT in Flutter stable** (Material frozen at 3.44; M3E deferred to a
  `material_ui` package still at v0.0.1). Do not chase it. Premium here = the brand system above +
  Material's real motion tokens (`Easing`, `Durations`) + one spring on the CTA.

## Assets still owed
Premium art; masters stay outside the repo. **Shipped 2026-08-03:** the launcher icon — red/gold
gopuram, RASTER masters also outside: `ic_launcher{,_foreground,_monochrome,_background}.png` in
`mipmap-mdpi…xxxhdpi`, composed (adaptive + `<monochrome>` layer) by `mipmap-anydpi-v26/ic_launcher.xml`.
Regenerate with
`node assets/brand/icon_from_png.mjs <icon.png> <splash.png>` — it ALSO writes
`assets/images/splash_bg.jpg`, which must be DELETED after a run: that art was rejected (§Motifs) and
anything left in assets/images/ ships in the APK.
**Shipped, no longer owed:** sign-in background video — `assets/video/splash.mp4` (1024×1824, same spec as
live wallpapers), loaded by `lib/features/auth/presentation/widgets/video_background.dart`.
