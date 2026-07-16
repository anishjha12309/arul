# Handoff: HSR CMS "Warm Sanctum Dark" Redesign

## Overview
End-to-end visual + UX redesign of the HSR CMS — an internal, single-operator admin managing wallpaper/ringtone content for two Android apps (Pakiza: Islamic content, 111 wallpapers + 51 ringtones, no categories; Arul: South-Indian devotional, 514 wallpapers in 6 categories, no ringtones). Replaces the current frosted-glass dark admin with an opaque, warm-charcoal, gold-accented system in the calibre of Linear/Vercel/Raycast.

## About the Design Files
`HSR CMS.dc.html` (+ `assets/`) is a **design reference built in HTML** — an interactive prototype showing intended look and behavior, NOT production code. The task is to **recreate this design inside the existing production codebase**: server-rendered **Hono JSX on Cloudflare Workers** — one CSS template string + vanilla-JS string constants in `cms/src/ui.tsx`, page JSX in `cms/src/pages/*.tsx`, HTMX for modal content loading. No client framework, no build step, no external assets beyond HTMX. Fonts stay system-stack.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii, and motion values below are final — implement them exactly.

## ⚠ Hard implementation constraints (must survive byte-exact)
The redesign is CSS/markup-styling only where these are concerned. Preserve exactly:
- All `data-*` behavioral attributes: `data-upload-form/-kind/-presign/-slot/-required/-upload-status/-upload-error`, `data-listview/-page/-search/-filter="N"` (N = column index), `data-page-size/-empty-filtered`, `data-grid/-grid-id`, `data-bulk-id/-all/-bar/-count/-act`, `data-view`, `data-dialog-target/-close`, `data-confirm`, `data-nav-toggle/-close`, `data-select-all/-selected-count/-transfer-go/-pickscope`, `hx-get/hx-target/hx-swap`.
- All form field names (`title`, `category`, `key_main`, `mime_main`, `id_main`, `items_json`, `is_published`, `ids`, `bulk_action`, `username`, `password`) and form actions.
- Script-queried classes: `.tablewrap`, `.pager`, `.filtered-out`, `.paged-out`, `th.sortable[data-type][data-dir]`, `tbody tr[data-id]`.
- The native `<dialog>` modals (the prototype's overlay div = restyle the `<dialog>` + `::backdrop`, don't replace it).
- The 52-test suite must pass: `cd cms && npx tsc --noEmit && npx vitest run`. Deploy stays manual (`npx wrangler deploy`).

## Design tokens (exact)
**Surfaces (all opaque — no glass-on-glass):**
- Page bg `#121013` · card `#191619` · elevated/modal `#201c20` · hover `#262126` / row-hover `#1e1a1e` · inset (JSON panels, inputs) `#100e10` · active-nav bg `#1d191d`
- Frosted blur survives on exactly TWO layers: modal scrim and mobile drawer scrim — `rgba(10,8,8,.55)` + `backdrop-filter: blur(8px)`.

**Borders do the elevation:**
- Resting `1px solid rgba(255,255,255,.08)` · hover `.14` (row separators `.05`) · controls `.12`–`.18`, control hover `.18`–`.35`
- Shadow only on true overlays (modal, bulk pill, toasts): `0 0 0 1px rgba(255,255,255,.06), 0 8px 24px rgba(0,0,0,.45)`

**Accent gold (≤8% of any screen):**
- Base `#d9a441` · hover `#e8b854` · pressed `#c1912f` · text-on-gold `#1a1408`
- Used ONLY for: primary CTA fill, active-nav 2px left bar + tinted label, focus rings, selected-card 2px rings, checked checkboxes, pending-submissions 6px signal dot, stat emphasis, toast left edge, category progress bars (`rgba(217,164,65,.14)` fill + `2px solid rgba(217,164,65,.55)` right edge).
- Secondary/outline gold buttons (dashboard "Review submissions"): transparent bg, `1px solid rgba(217,164,65,.5)`, text `#e8b854`.

**Text (warm whites, never pure):**
- Primary `#ece8e1` · body/secondary `rgba(240,235,228,.75–.8)` · muted `.55–.6` · faint `.4–.5` · labels `.38–.45`
- Status green (published dot) `#6faa78` (desaturated) · danger `#e06c5f` · draft dot `rgba(240,235,228,.35)`

**Type (system stack: `-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif`):**
- Body 14/1.5 · labels 13/600 · table 13.5 · page titles 24/700, letter-spacing −0.02em · section micro-labels 11/700 uppercase +0.06em · brand "HSR" 16/700 with 22×2px gold underline, "UNIFIED CMS" 10/700 +0.08em
- Mono (IDs/keys/versions/JSON): `ui-monospace, SFMono-Regular, Menlo, monospace`, 12px, 65% opacity. All numbers `font-variant-numeric: tabular-nums`. Stat hero numbers 28/700.

**Spacing / geometry:** 8px grid · table rows 40px, cell padding 9×14 · card padding 16 · sidebar 232px · thumbnails 36×36 · modal 520px (review 620px) · login card 380px · grid cards `minmax(180px,1fr)`, aspect-ratio 9/16.

**Radii:** 6px controls/buttons · 10px cards/inputs · 14px modals · 4px checkboxes · pill (999px) ONLY for small chips (version chip, LIVE/draft chips) and the floating bulk bar. **No pill buttons.**

**Motion:** 120ms hover (border/opacity/color only — no background swaps except segmented control) · 160ms press · 220ms modal/drawer entrance with `cubic-bezier(0.16,1,0.3,1)` (modal: translateY(14px) scale(.985)→none + fade; drawer: translateX(−100%)→0) · bulk pill 200ms slide-up (translateY 64px→0 + fade) · toast 200ms translateY(10px)→0 · skeleton shimmer: opacity .55↔.75, 1.6s ease-in-out loop. Nothing bouncy/staggered.

**Focus:** every interactive element gets `outline: 2px solid rgba(217,164,65,.55); outline-offset: 2px` via `:focus-visible`. Inputs additionally swap border-color to `rgba(217,164,65,.55)` on focus.

**Scrollbars:** thin; thumb `rgba(240,235,228,.14)` (hover `.28`), 999px radius, 3px `#121013` border, transparent track. Firefox: `scrollbar-width: thin`.

**Selects:** `appearance:none` + inline-SVG chevron (10×6, stroke `#a89f93`, 1.5w) at `right 10px center`, padding-right 28px.

## Screens

### Login
Centered 380px card (`#191619`, 1px border, r14, padding 32/28). "HSR CMS" 20/700 → 28×3px gold bar → "UNIFIED CMS" micro-label. Username + password fields (inset bg, r10). Full-width gold submit, r6 — **disabled** (bg `#262126`, text 40%) until both fields are non-empty. Enter submits. Autofocus username.

### Sidebar (persistent, 232px)
Brand block (see type). Groups: OVERVIEW (Dashboard) · PAKIZA (Wallpapers, Ringtones, Submissions, App config) · ARUL (Wallpapers, Submissions, Category transfer, App config). Item: 13.5/600, `rgba(240,235,228,.6)`, padding 8px 20px 8px 18px, 2px transparent left border. Active: 2px gold left bar + `#ece8e1` text on `#1d191d`. Hover: text brightens only. Pending>0: 6px gold dot after "Submissions" label. Sign out = ghost button pinned to bottom edge with top hairline.
**Mobile (<900px):** sidebar → hamburger (36×36 ghost button) in a sticky top bar; drawer 272px slides in 220ms over blurred scrim, same content, × top-right, Sign out pinned to the drawer's bottom edge (no dead gap). Esc and scrim-click close.

### Dashboard
24px title + muted subtitle. Per app, ONE header row: name 17/700 + mono version chip (`v228`, hairline pill) + spacer + ghost action buttons (`white-space:nowrap`) with "Review submissions" as gold-outline variant carrying the 6px gold dot when pending>0. Stat tiles: hairline cards, 28px tabular hero number + muted 13px label — no icon circles. Arul adds "PUBLISHED BY CATEGORY" card (spans 2 tile columns): each category row has an absolute-positioned gold progress bar (published/total width) behind capitalized name + `bold pub / muted total` counts.

### Wallpapers list (core screen)
Header: "{App} wallpapers" + "{N} entries" muted; right: gold "+ New wallpaper".
Toolbar, one row (wraps): search (⌕ glyph inside at left 11px; placeholder "Search title, category, ID or R2 key…"; clear × appears when non-empty) · type select (All/Static/Live) · status select (All/Published/Draft) · spacer · Table⇄Grid segmented control (active segment bg `#262126`) · page-size select (20/50/100).
Search matches title, ID, category, and R2 key, case-insensitive.
**Table:** container `#191619` r10 hairline; sticky header (11/700 uppercase muted); 40px rows; hairline row separators `.05`; custom 16px checkboxes (gold fill + `#1a1408` ✓ when checked, header = select-all of filtered set); 36×36 r6 thumbnail; title 600, ellipsized; type/category plain muted text; status = 6px dot (`#6faa78` / faint) + lowercase word; short-ID mono 12/65%; date muted tabular. Row actions cluster: resting opacity .5 → 1 on hover, never hidden; Edit + Unpublish/Publish = ghost hairline; **Delete = ghost danger** (red text `#e06c5f`, transparent bg + border, red border on hover).
**Grid:** `repeat(auto-fill, minmax(180px,1fr))` gap 12; 9/16 cards r10 hairline; image = cover; LIVE chip top-left (mono 10px uppercase pill, `rgba(16,14,16,.75)` bg, hairline); drafts: image at 60% opacity + "draft" chip (stacks below LIVE); checkbox top-right at 45% opacity → 1 on hover or once any selection exists; selected = 2px gold inset ring; bottom gradient bar (`transparent → rgba(10,8,8,.85)`) with title + mono short-ID. Clicking the image opens Edit; the checkbox stops propagation.
**Bulk actions:** floating pill, bottom-center of the content column, slides up 200ms on first selection: "N selected" (tabular) · divider · ghost Publish · ghost Unpublish · ghost-danger Delete · ×  clears. Identical in both views. Elevated surface + overlay shadow. NOT a top banner.
**Pagination row:** "1–20 of 111" muted left; Prev (disabled 40%) · "Page 1 / 6" · Next ghost right.
**Mobile:** table view and view toggle disappear (grid only, exactly 2 columns); bulk pill spans full width minus 16px margins.

### Create / Edit modal
Restyle the native `<dialog>`: 520px, `#201c20`, r14, 1px border `.1`, overlay shadow, 220ms pop; ONE blurred scrim (`::backdrop`). 18/700 title + ghost ×. Fields: Title (autofocus) · Category (Arul only — free-text input + `<datalist>` of existing categories) · media: dashed-hairline dropzone (`1px dashed rgba(255,255,255,.18)`, r10, centered ⇪ glyph + "Drop files or browse — select several to create a batch"; hover: gold-tinted dash `rgba(217,164,65,.45)`); Edit shows "Replace media (optional)" + "Current: {full R2 key}" in mono 12/55%, word-break; helper line "JPG/PNG/WebP = static · MP4 = live. Run ffmpeg locally first (no server transcode)." 12/40%. Published checkbox (create only, default checked). Upload progress inline in gold: "File 2 of 5…" → "5 files uploaded ✓". Footer right-aligned: ghost Cancel + gold primary; primary shows "Uploading…/Saving…" and disables (bg `#262126`) while busy. Esc closes.

### Ringtones (Pakiza)
Same table language minus thumbnail/category/type columns: 36×36 r6 `#262126` tile with muted ♪, title, status dot, mono ID, date, same row actions. Search placeholder "Search title, ID or file key…". Create/edit modal = same pattern, single audio file ("Drop an MP3 or browse", hint "MP3 up to 2 MB. Title gets slugged into the file key.").

### Submissions
Segmented control Pending/Approved/Rejected (same language as view toggle). Table: kind, title (600), category (— if none), date, one always-visible ghost "Review" action. Empty state: single muted sentence ("No pending submissions."), nothing else. Review modal (620px): left 180px 9/16 media preview (video autoplays in production; LIVE chip), right column: Title override, Category override (Arul), "Rejection reason (optional)" input, footer: ghost-danger Reject + gold Approve. Approve/reject move the row between tabs and update all pending dots.

### Category transfer (Arul)
Three stacked hairline cards with mono micro-labels: **01 · SOURCE** — category select ("murugan · 113 items"); **02 · PICK** (appears once source chosen) — same card-grid language as wallpapers grid at `minmax(120px,1fr)`, tap toggles, gold ring + top-right gold ✓ when picked, "N of M selected" + Select all/Clear all ghost button; **03 · TARGET** — free-text input + datalist suggestions + Move button (disabled `#262126` until ≥1 picked and target ≠ source; label "Move N items") + per-item mono result report on inset panel: `✓ 82d56501 · Lord Murugan → temples`. Failed/missing thumbnails render a neutral `#201c20` tile with a centered ▶ glyph at 35% — never a broken-image box.

### App config
Title + mono `content_version vNNN`; ghost "Rebuild now" top-right. One card: Support email + Minimum supported app version (2-col grid) · three JSON textareas (prices, policy_urls, feature_flags) with micro-labels, mono 12.5/1.55 on inset `#100e10` r10 panels, vertical resize · gold "Save & rebuild" + inline status text ("Saving & rebuilding catalog…" → "Catalog rebuilt · v229"). Both buttons disable and show "Rebuilding…" while busy; version chip increments on completion.

## Interactions & behavior (quality-of-life — implement all)
- **Toasts:** bottom-right stack, `#201c20` r10, hairline + 2px gold left edge, overlay shadow, 200ms slide-in, auto-dismiss 3.2s (5.2s with Undo), ghost ×. Fire on: publish/unpublish (single + bulk with counts), create ("3 wallpapers created · published"), save changes, approve/reject (includes reason), transfer ("4 items moved to temples"), config rebuilt.
- **Undo on delete:** row and bulk deletes toast with a gold "Undo" that restores the removed rows (snapshot-and-restore; in production, soft-delete or deferred commit).
- **Disabled/busy buttons:** never spinner-less dead clicks — busy label swap + `#262126` bg + default cursor; guard double submits.
- **Loading:** brief skeleton (hairline card, shimmer rows echoing table geometry) while a list loads.
- **Keyboard:** Esc closes modal, then drawer; Enter submits login; visible gold focus rings everywhere.
- **Hover:** borders brighten / opacity sharpens; backgrounds swap only on table rows (`#1e1a1e`) and segmented controls.
- All button/label text `white-space: nowrap` so mid-width viewports never wrap labels.

## State management (prototype → production mapping)
Prototype state (all client-side): route/app, list data per app, search/type/status filters, view mode, selection set, modal kind, submission tabs, transfer (src/picked/target/report), config drafts + busy flags, toasts, narrow (matchMedia 900px). In production most of this already exists via the vanilla-JS constants + HTMX; the redesign only adds: bulk pill show/hide, toast manager, undo snapshot, busy-button states, skeleton, drawer Esc-close.

## Anti-patterns (do NOT reintroduce)
Glass-on-glass stacking · gold fills larger than a button · bootstrap icon-circle stat cards · hover-only critical actions · pill-shaped buttons · bouncy/staggered/parallax motion (>220ms) · pure black · literal religious iconography in the chrome · webfonts.

## Assets
`assets/p01–p20.png` (Pakiza 9:16 thumbs) and `assets/a01–a20.png` (Arul square thumbs) are cropped from the current CMS screenshots — placeholder stand-ins for the real R2 thumbnails; do not ship them.

## Files
- `HSR CMS.dc.html` — the full interactive prototype (all screens, both apps, desktop + mobile). Template markup at top, logic class + sample data at bottom.
- `assets/` — thumbnail placeholders used by the prototype.
