# Handoff: Arul — "Ringtones" screen (dark + light)

## Overview
The Ringtones tab of **Arul**, a South Indian devotional wallpaper & ringtone app. Users browse devotional ringtones by deity category, preview one at a time, and set a tone as their ringtone. This handoff covers both themes of one mobile screen (390×844) plus the floating bottom navigation dock shared across the app.

## About the Design Files
`Arul Ringtones.dc.html` in this bundle is a **design reference created in HTML** — a prototype showing intended look and behavior, not production code to copy. The task is to **recreate this design in the app's existing environment** (React Native / Flutter / SwiftUI / Kotlin — whatever the Arul app is built in), using its established components, theming, and icon set. If no environment exists yet, pick the framework appropriate for the project and implement there.

Two things in the HTML are implementation-specific and should be re-expressed natively:
- The cover-art medallions are generated as inline SVG in JS. In the app they should be generated the same way (procedural SVG / Canvas / vector drawing), not shipped as 8 static image files — the ground palette, motif, and kolam ring are data-driven per track.
- The two phone frames side by side exist only so both themes can be reviewed together. The app renders one screen; theme comes from the app's theme provider.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii, and states are final and taken from Arul's existing design system. Recreate pixel-for-pixel using the codebase's primitives. Where the codebase already has a token for a value listed below, use the token rather than the raw hex.

## Screens / Views

### Ringtones (single screen, two themes)
**Purpose:** browse devotional ringtones by deity category, preview audio, set a ringtone.

**Layout** — vertical stack inside a 390×844 viewport:

| Band | Height | Notes |
|---|---|---|
| Status bar | 44 | system |
| Header row | ~44 (padding-top 6) | title left, Earn chip right; horizontal padding 16 |
| Category chip row | 64 (padding 16 top / 14 bottom) | horizontally scrollable, no visible scrollbar |
| Ringtone list | fills remainder (~626) | vertical scroll, hidden scrollbar, gap 10, horizontal padding 16, **padding-bottom 120** so the last row clears the dock |
| Floating dock | 78, absolutely positioned | left/right 18, bottom 14, overlays the list; list scrolls behind it |

**1. Header**
- Title "Ringtones" — Marcellus 27px, line-height 1.1. Dark `#FAF5EC`; light `#2B1116`.
- "Earn" chip — height 38, padding 0 15, radius 999, gap 7, icon 16×16 gift outline + label 13.5px/600.
  - Dark: fill `rgba(212,160,23,0.12)`, border 1px `rgba(212,160,23,0.45)`, icon+text `#D4A017`.
  - Light: fill `rgba(122,30,51,0.07)`, border 1px `rgba(122,30,51,0.18)`, icon+text `#7A1E33`.

**2. Category chips** — `All · Amman · Ayyappan · Murugan · Perumal · Sivan · Temples`. Category is the only browse axis; there are **no All/New tabs**. Height 34, padding 0 16, radius 999, gap 8, font 13.5px (600 active, 500 inactive). Active = `All`.
- Dark active: fill `#D4A017`, text `#14090C`. Dark inactive: fill `rgba(250,245,236,0.045)`, border 1px `rgba(250,245,236,0.12)`, text `#B9A58F`.
- Light active: fill `#7A1E33`, text `#FAF5EC`. Light inactive: fill `#FFFFFF`, border 1px `rgba(122,30,51,0.12)`, text `#6B5240`.

**3. Ringtone row (card)** — radius 15, padding 9px 12px, flex row, `align-items: center`, gap 12. Children in order:
- Cover art 46×46, flex-none (see "Cover art" below).
- Title — flex 1, min-width 0, single line, ellipsis. Sans 15px/500, letter-spacing 0.005em.
- Play/pause button — 34×34 circle, centered icon 15×15, hit area should be expanded to ≥44px in the native build (the visual stays 34).
- "Set" pill — height 32, padding 0 16, radius 999, 13.5px/600, outlined. Same ≥44px hit-target note.

Row states:

| | Dark idle | Dark now-playing | Light idle | Light now-playing |
|---|---|---|---|---|
| card fill | `rgba(250,245,236,0.045)` | `rgba(212,160,23,0.10)` | `#FFFFFF` | `rgba(212,160,23,0.10)` |
| card border 1px | `rgba(250,245,236,0.09)` | `rgba(212,160,23,0.52)` | `rgba(122,30,51,0.12)` | `rgba(212,160,23,0.52)` |
| title | `#FAF5EC` | `#D4A017` | `#2B1116` | `#A3760F` |
| button fill | transparent | `#D4A017` | `#FFFFFF` | `#D4A017` |
| button border | `rgba(250,245,236,0.22)` | `#D4A017` | `rgba(122,30,51,0.18)` | `#D4A017` |
| button glow | none | `0 0 14px rgba(212,160,23,0.35)` | none | same |
| button icon | play `#FAF5EC` | pause `#14090C` | play `#2B1116` | pause `#14090C` |
| cover art | plain medallion | scrim + diya (below) | plain | scrim + diya |

"Set" pill is identical in both row states — dark: border `rgba(250,245,236,0.22)`, text `rgba(250,245,236,0.86)`; light: border `rgba(122,30,51,0.18)`, text `#7A1E33`.

Content (8 rows, in order): Kanda Sashti Kavasam, Om Namah Shivaya, Kolaru Pathigam, Vishnu Sahasranamam, Harivarasanam, Aigiri Nandini, Thiruppugazh, Suprabhatam. Row 3 (Kolaru Pathigam) is shown in the now-playing state.

**4. Floating bottom dock** — absolutely positioned, left/right 18, bottom 14, height 78, radius 26, inner horizontal padding 10. Three equal-flex tabs, each a 58-tall column: icon 22×22 above label, gap 6, label 12.5px (600 active / 500 inactive). All three tabs show icon **and** label. Tabs: Wallpapers · Ringtones · Settings; Ringtones active.
- Dark dock: fill `#1B1215`, border 1px `rgba(250,245,236,0.08)`, shadow `0 16px 38px rgba(0,0,0,0.6)`, backdrop-blur 14. Active tab: radius 18, fill `rgba(212,160,23,0.13)`, border 1px `rgba(212,160,23,0.45)`, glow `0 0 20px rgba(212,160,23,0.16)`, icon+label `#D4A017`. Inactive icon+label `#8F7C68`.
- Light dock: fill `#FFFFFF`, border 1px `rgba(122,30,51,0.08)`, shadow `0 14px 34px rgba(43,17,22,0.14)`. Active tab: radius 18, fill `#F0DCAA`, border 1px `rgba(212,160,23,0.5)`, icon+label `#2B1116`. Inactive icon+label `#8A6F5C`.

Icons (all 24×24 viewBox, stroke-only, round caps):
- Wallpapers: rounded rect + small circle + mountain polyline, stroke 1.5.
- Ringtones: music note — circle r2.9 at (9,17.6), stem to y5.6, flag curve, stroke 1.7.
- Settings: cog — inner circle r3.2 stroke 1.5 + outer circle r7 stroke 2.4 with dash `1.7 3`.
- Earn: gift — rounded rect `3.5,9.5 17×10.5 r2`, centre vertical line, two bow curves, stroke 1.5.

## Cover art — the signature element
Unique procedural artwork per ringtone, 46×46, radius 13, no photography. Four layers, bottom to top:

1. **Ground** — 135° linear gradient (top-left → bottom-right) from a 10-entry jewel-tone temple palette; vary across visible rows:
   `#5C1226→#2A0A12` (maroon) · `#0E3B2E→#07231B` (temple green) · `#1E2159→#0E0F2E` (indigo) · `#0B4550→#04252C` (peacock teal) · `#7A5410→#3A2606` (turmeric ochre) · `#40154A→#210A28` (aubergine) · `#6B2A12→#33130A` (brick) · `#5E1839→#2C0A1B` (deep rose) · `#3F4A12→#1E2408` (olive) · `#12335A→#08192E` (navy).
   Plus an inset hairline rim: `stroke #EBD6A3`, width 0.7, opacity 0.18, inset 0.5, radius 12.5.
2. **Kolam ring** — pulli dots on a circle of radius 15 about centre (23,23): dot count 8 / 12 / 16 and start rotation vary per track; each dot `r 1.05`, fill `#EBD6A3`, opacity 0.5. Some tracks add a woven line: circle r15, stroke `#EBD6A3`, width 0.85, opacity 0.3, dash `2 3.6`.
3. **Centre motif** — decided by the track's deity category, minimal gold line-work: stroke `#EBD6A3`, width 1.15, no fill, round caps/joins.
   - Murugan → **vel**: shaft `M23 32 V20`, diamond head `M23 12.4 L26 19.4 L23 21.4 L20 19.4 Z`, peacock eye circle r2.4 at (23,27) opacity 0.85 + solid dot r0.75.
   - Sivan → **trishul + damaru**: shaft `M23 33 V13`, prongs `M17.6 17 V12.2`, `M28.4 17 V12.2`, crossbar `M17.6 17 H28.4`, damaru `M20.4 24.6 H25.6 L20.4 30.4 H25.6` at opacity 0.85.
   - Amman → **lotus**: centre petal `M23 31 C20.4 27 20.8 20.6 23 16.4 C25.2 20.6 25.6 27 23 31`, two side petals mirrored about x=23, plus two waterline strokes `M23 31 H13.6` / `H32.4` at opacity 0.7.
   - Perumal → **shankha + chakra**: chakra circle r5 at (29.2,24) with 4 spoke lines at opacity 0.7; conch `M18.8 16.6 C14.4 18.6 13.6 25.4 16.6 28.6 C18.6 30.8 20.8 29 19.8 26.6 C19 24.6 17.8 22.4 18.8 16.6 Z`.
   - Ayyappan → **18 sacred steps**: stair `M12.6 32.4 h4.6 v-3.6 h4.6 v-3.6 h4.6 v-3.6 h4.6 v-3.6 h3.4` + finial dot r1.1 at (32.6,15.6).
   - Temples → **gopuram**: three stacked trapezoid tiers `M12.4 33 L14.6 26.6 H31.4 L33.6 33 Z`, `M15.4 26.6 L17.4 20.6 H28.6 L30.6 26.6`, `M18.2 20.6 L20 15.4 H26 L27.8 20.6`, finial `M23 15.4 V12`.
   At least four different motifs must appear across the visible rows.
4. **Now-playing overlay** (only on the playing row) — scrim `rgba(14,6,8,0.66)` over the full tile (radius 13), then a gold **diya**:
   - glow: circle r9 at (23,21), radial gradient `#F4DFA8 @75% opacity → #D4A017 @0`.
   - bowl: `M14.6 27.6 C16.6 32.4 29.4 32.4 31.4 27.6 Z`, fill `rgba(212,160,23,0.35)`, stroke `#EBD6A3` 1.1.
   - base: `M17.4 32.4 H28.6`, stroke `#EBD6A3` 1.1.
   - flame: `M23 26.4 C25.8 23.6 24.8 19.6 23 16.6 C21.2 19.6 20.2 23.6 23 26.4 Z`, fill `#F6E3AE`.

All medallion line-work uses one warm gold ink, `#EBD6A3`, across every tile.

## Interactions & Behavior
- **Play/pause:** tapping a row's circular button starts preview of that track and moves the now-playing state to it; tapping the playing row's button pauses and clears the state (no row highlighted). Only one row can be playing at a time. Row highlight, title colour, button fill, and cover-art overlay all derive from that single value.
- **Flame flicker:** the diya flame sways continuously while playing — `1100ms ease-in-out infinite alternate`, `transform-origin` at the flame base (23,30), keyframes `rotate(-4°) scaleY(0.94)` → `rotate(2°) scaleY(1.05)` → `rotate(-2°) scaleY(0.97)`. The glow circle pulses on the same 1100ms cycle, opacity 0.28 → 0.5 → 0.32. Respect reduced-motion: hold the flame static with glow opacity 0.4.
- **Set:** applies the tone as the device ringtone (permission flow is out of scope for this design).
- **Category chips:** selecting a chip filters the list; selected chip becomes the solid fill style. Chip row scrolls horizontally with no visible scrollbar.
- **Earn:** opens the rewards/earn entry point.
- **Dock:** switches between Wallpapers / Ringtones / Settings. Dock floats above the list in both themes and never scrolls away.
- **Scrolling:** the list scrolls behind the dock; keep 120px bottom inset so the last row is fully reachable.
- Loading state: use the existing skeleton shimmer — base `#14090C` → highlight `#2A1218` on dark.

## State Management
- `selectedCategory: 'All' | 'Amman' | 'Ayyappan' | 'Murugan' | 'Perumal' | 'Sivan' | 'Temples'` — drives list filtering.
- `nowPlayingId: string | null` — single source for all now-playing styling; clearing it must stop audio.
- `tracks: Track[]` where `Track = { id, title, category, motif, groundIndex, kolamDots: 8|12|16, kolamRotation: number, weave: boolean, audioUrl }`. Cover-art parameters should come from the track record (stable per track, so a tile always looks the same) — derive them deterministically from the track id if the API doesn't supply them.
- `activeTab` for the dock, owned by the app shell.
- Audio playback belongs to a single shared player service so navigating away can stop preview.

## Design Tokens
**Brand:** maroon `#7A1E33` (hover `#8D2740`) · gold `#D4A017` · ivory `#FAF5EC` · dark surface `#14090C` · CTA green `#1FA75A` · gold ink `#EBD6A3`.

**Dark theme:** bg `#14090C`; text primary `#FAF5EC`, secondary `#B9A58F`, muted `#8F7C68`, faint `#6E5C4C`; card fill ivory 4–5%; card border ivory 9% (14% emphasised); divider ivory 8%; tinted chip fill gold 10–14%; hairline gold 35–50%; skeleton `#14090C` → `#2A1218`.

**Light theme:** bg `#FAF5EC`; text primary `#2B1116`, secondary `#8A6F5C`, body `#6B5240`, faint `#B09A86`; card fill `#FFFFFF`; card border maroon 12% (18% emphasised); divider maroon 10%; tinted fill maroon 7–8%.

**Typography:** display = **Marcellus** (Google Fonts); UI = system sans. Screen title 22–30px (27 used here) · row title 15/500 · row subtitle 12.5 · chips 13.5 (500 inactive / 600 active) · buttons 15/600 · dock labels 12.5 · small badges 10.5/700 uppercase letter-spacing 0.14em.

**Spacing:** screen padding 16 · content gap 16 · list row gap 10 · row inner gap 12 · minimum hit target 44.

**Radii:** cards 20 · list rows 15 · cover art 13 · dock 26 · dock active tab 18 · small icon-chips 12 · pills 999.

**Shadows:** dock dark `0 16px 38px rgba(0,0,0,0.6)` · dock light `0 14px 34px rgba(43,17,22,0.14)` · gold glow `0 0 20px rgba(212,160,23,0.16)` (dock) / `0 0 14px rgba(212,160,23,0.35)` (playing button).

## Assets
No raster assets. Everything is vector: cover art is procedural SVG, all icons are inline stroke SVG described above. Only external dependency is the **Marcellus** webfont (Google Fonts) — substitute the app's bundled copy if one exists.

## Files
- `Arul Ringtones.dc.html` — the design reference: both themes side by side, interactive play/pause, procedural cover art, animated diya. Open directly in a browser. Cover-art generation and row-state logic are in the `<script data-dc-script>` block at the bottom (`medallion()`, `motifEls()`, `buildRows()`); all screen layout and styling is inline in the markup above it.
