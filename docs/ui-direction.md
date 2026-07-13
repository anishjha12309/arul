# UI Direction — Arul

> **BUILT 2026-07-14** — this is now a description of shipped code (`lib/app/theme`, `lib/app/widgets`),
> not a proposal. Change the tokens, not the screens. Perf rules that shape the design are in §Perf.

**The UI/UX is Arul's own.** Screens, layout and navigation chrome are designed fresh — do NOT
clone the reference app's look. What stays FIXED regardless of design: logic/data layers, entitlement
gating, and every behavioral contract in docs/edge-cases.md. One structural constant: the wallpaper
feed remains a **vertical Shorts-style pager** — the whole native video pipeline (player pool,
prefetch, decoder budget) is built around that paradigm; changing it = rebuilding the video layer.
Load the frontend-design skill when building screens. Tokenize every color — no literals in screens.

## Brand
- **Name:** Arul (दक्षिण / தக்ஷிண — "the South"). Wordmark: `Arul`, tagline `SOUTH INDIAN WALLPAPERS`.
- **Feel:** Kanjivaram silk + temple gold — rich, warm, **devotional**. The launch catalog IS deity
  content: Amman, Ayyappan, Murugan, Perumal, Sivan + Temples (428 curated items). Design reverent,
  not kitsch: deep silks, gold, oil-lamp warmth; no cartoon deity clip-art chrome.
- **Browse = CATEGORY, always.** A category chip row over the feed: All · Amman · Ayyappan · Murugan ·
  Perumal · Sivan · Temples (client-side filter on the catalog's `category` field). This REPLACES the
  reference's All/New tabs. Static and live wallpapers interleave inside every category — **never
  filter or tab by static/live**; type is a rendering detail the user shouldn't have to think about.

## Palette (fixed seed — CLAUDE.md §7; never dynamic color)
| Token | Value | Use |
| --- | --- | --- |
| maroon (primary) | `#7A1E33` | brand seed, accents, active states |
| gold (accent) | `#D4A017` | highlights, premium badging, selection |
| ivory | `#FAF5EC` | light surfaces |
| darkSurface | `#14090C` | dark surfaces + splash (matches pubspec splash color) |
| ctaGreen | `#1FA75A` | primary CTA (proven affordance in the reference — keep) |
Light + dark themes both required, persisted.

## Type
Base: Roboto (system). Display/wordmark: a serif with presence (e.g. Playfair Display via
google_fonts) — but every locale string must render in Tamil/Telugu/Kannada/Malayalam scripts,
so display fonts apply ONLY to the Latin wordmark; all UI text uses the base stack (Noto fallbacks).

## Motifs
Sign-in + splash backgrounds: **kolam dot-grid patterns** (subtle line-drawn loops), **gopuram
silhouette** gradient at the horizon, gold particle shimmer — CustomPainter + video-bg variant
(same architecture as the reference's painter, entirely new artwork). Premium screen: silk-texture
gradient (maroon→deep plum) with gold zari border strips; benefits copy is wallpaper-focused.

## Copy tone
English + 5 South Indian languages. Warm, festive, plain — no religious salutations. Share message
pattern: "Beautiful South Indian wallpapers — get Arul: <link>".

## Perf rules that SHAPE the design (not optional polish)
- **No glassmorphism.** `BackdropFilter` costs ~6–9ms raster/frame on mid-tier Android — it would eat
  the budget the video decoder needs. Chrome legibility comes from gradient scrims
  (`ArulScrims.top/bottom`), which are ordinary paints. This is why the feed looks the way it does.
- **No `shimmer` package / no `ShaderMask`** — a mask forces `saveLayer()`, an offscreen pass per
  frame. `lib/app/widgets/skeleton.dart` slides a gradient FILL instead: identical look, zero cost.
- **No `google_fonts`, no `font_awesome_flutter`** — runtime font fetching and whole icon fonts. The
  system stack already renders Latin + all 5 Indic scripts for free; built-in `Icons` tree-shake.
- Feed pages get no keep-alive and no extra RepaintBoundary (PageView.builder adds one already).
- Images decode at display size (`memCacheWidth` × devicePixelRatio); the image cache is capped in
  `main.dart` — a 1080×1920 wallpaper is ~8.3 MB of RGBA regardless of file size.
- **Material 3 Expressive is NOT in Flutter stable** (Material is frozen at 3.44; M3E is deferred to a
  `material_ui` package that is still a v0.0.1 placeholder). Do not chase it. Premium here = the brand
  system above + Material's real motion tokens (`Easing`, `Durations`) + one spring on the CTA.

## Assets still owed
Real launcher-icon artwork (a vector gopuram mark ships now: `android/.../ic_launcher_foreground.xml`
+ a `<monochrome>` themed layer) · sign-in background video (1024×1824, same spec as live wallpapers)
· premium art. Keep masters outside the repo.
