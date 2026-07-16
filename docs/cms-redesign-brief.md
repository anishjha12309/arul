# HSR Unified CMS — UI/UX Redesign Brief (for Claude Design)

> **How to use:** paste everything below the line into **Claude Design** as the
> prompt, and attach the current-UI screenshots from `docs/cms-redesign-shots/`
> — at minimum: `02-dashboard`, `11-arul-wallpapers-table`,
> `12-arul-wallpapers-grid`, `05-pakiza-wallpapers-bulkbar`,
> `06-pakiza-wallpapers-create-modal`, `13/14-arul-transfer`,
> `17-mobile-dashboard`, `19-mobile-nav-drawer`. The final section is a
> handoff appendix for when the design comes back to Claude Code for
> implementation — include it in the paste so it travels with the bundle.

---

Redesign this admin CMS end-to-end. The attached screenshots are the CURRENT
state — a competent but generic "frosted-glass dark admin". I want it
**functional, usable, and premium** — the calibre of Linear, Vercel, or
Raycast. Produce high-fidelity screens (desktop 1440 and mobile 390) for every
page listed below, as an interactive prototype where possible.

## What this product is

"HSR CMS" — an internal, single-operator admin tool managing wallpaper content
for TWO Android apps from one login:

- **Pakiza** — Islamic content: 111 wallpapers (static images + live videos) +
  51 ringtones. No categories.
- **Arul** — South-Indian devotional content: 514 wallpapers in 6 categories
  (amman, ayyappan, murugan, perumal, sivan, temples). No ringtones.

All wallpaper media is vertical 9:16 (phone wallpapers); every item has a real
thumbnail, including videos. The operator works in short daily bursts: upload
batches, moderate user submissions, find one specific item among hundreds of
identically-titled rows (that's why lists show short IDs and search matches
ID/R2-key), and occasionally bulk publish/unpublish/delete.

**Pages:** Login · Dashboard (both apps' stats) · per-app Wallpapers list
(table view + thumbnail-grid view, create/edit modals, multi-select with bulk
actions) · Ringtones (Pakiza only) · Submissions moderation queue (pending /
approved / rejected tabs, review modal with media preview + approve/reject) ·
Category transfer (Arul only: pick source category → multi-select items →
move to target category) · App config (JSON textareas + save/rebuild) ·
persistent left sidebar (Overview / Pakiza / Arul groups) that becomes a
hamburger drawer on mobile.

## Art direction (decided — execute this, don't explore alternatives)

**"Warm sanctum dark."** Warm charcoal base with a subtle ochre undertone
(`#131110` ballpark) — temple-lamp warmth with ZERO literal religious motifs
(it must feel equally right for Islamic and Hindu devotional content, and the
warmth must come only from the neutral palette). **Gold becomes THE accent,
replacing the current iOS blue entirely.** Everything else is
graphite-precision discipline: monochrome opaque surfaces, hairline borders,
restrained fast motion.

## Design system (exact values — use these)

- **Surfaces (opaque — kill the current glass-on-glass):** page `#121013` →
  card `#191619` → elevated/modal `#201c20` → hover `#262126`. Never pure
  black. Frosted blur survives on EXACTLY one layer: the modal scrim (and the
  mobile drawer). Everything else flat.
- **Borders do the elevation:** 1px `rgba(255,255,255,.08)` resting, `.14` on
  hover, `.18` on controls. Shadows only on true overlays: `0 0 0 1px
  rgba(255,255,255,.06), 0 8px 24px rgba(0,0,0,.45)`.
- **Accent = gold, disciplined:** `#d9a441` (hover `#e8b854`, pressed
  `#c1912f`, text-on-gold `#1a1408`). Gold appears ONLY as: primary CTA fill,
  active-nav indicator (2px left bar + tinted label — not a filled pill),
  focus rings, selected-card rings, checked checkboxes, the
  pending-submissions "signal dot", stat emphasis. Target ≤8% of any screen's
  pixels. Never gold on large areas. Semantic green/amber/red stay for
  status/danger, desaturated ~15% to sit in the warm palette.
- **Type (system font stack; no webfonts):** body 14/1.5 · labels 13/600 ·
  table 13.5 · page titles 24/700 tracking −0.02em (current 30px headers are
  oversized for a tool) · section micro-labels 11/700 uppercase +0.06em.
  IDs/keys/versions in monospace 12px at 65% opacity. All numbers tabular.
- **Spacing:** 8px grid. Table rows 40px (current ~66px is too airy), cell
  padding 9×14. Card padding 16. Sidebar 232px.
- **Radii:** 6px controls · 10px cards/inputs · 14px modals. **No pill-shaped
  buttons** — the current pills are the single biggest "consumer app" tell.
  Small badges/chips may stay pill.
- **Motion:** 120ms hover · 160ms press · 220ms modal/drawer entrance with
  expo-out `cubic-bezier(0.16,1,0.3,1)` · 140ms exits. Hover = border
  brightening / opacity shift, not background swaps. Nothing bouncy or
  staggered.
- **Focus:** visible 2px gold ring (55% opacity, 2px offset) on every
  interactive element.

## Screen-by-screen requirements

### Dashboard
- One-line header row per app: name + catalog-version chip + action buttons
  (reduce the current double-header bulk).
- Stat tiles: hero number 28px tabular, muted label, hairline card — NOT the
  bootstrap "icon-in-circle" pattern.
- Arul's "Published by category" card: each category row gets a thin gold
  progress bar (published/total) behind the count — the only chart-like
  element on the page.
- When pending submissions > 0: a small gold dot on the "Review submissions"
  button and the sidebar item (signal-light pattern, like a notification LED).

### Wallpapers list — THE core screen, spend the most care here
- Toolbar, one row: search field (⌕ glyph inside; placeholder "Search title,
  category, ID or R2 key…") · type filter (All/Static/Live) · status filter
  (All/Published/Draft) · Table⇄Grid segmented control · page-size select.
- **Table view:** 40px rows; sticky header; 36×36 rounded-6 thumbnail; title
  600-weight; type + category as plain muted text; status = 6px colored dot +
  word (not a pill); short-ID mono; date muted. Row actions
  (Edit / Unpublish / Delete) sharpen on row hover but keep ≥40% resting
  opacity — never fully hidden. Delete is GHOST danger (red text, transparent
  bg, red border on hover) — the current page of 20 filled-red Delete pills
  screams.
- **Grid view:** 9:16 cards ~200px wide; LIVE = tiny mono uppercase chip
  top-left; draft cards at 60% opacity + "draft" chip; title + short-ID in a
  bottom gradient bar. Selection checkbox top-right resting at 45% opacity →
  full on hover or once any selection exists; selected card = 2px gold ring.
  Clicking the image opens Edit.
- **Bulk actions = floating pill, bottom-center** (slides up 200ms on first
  selection): "N selected" + Publish · Unpublish · Delete + an "×" that clears
  the selection. Works identically in table and grid view. NOT a top banner
  (current design) — it competes with the header.
- **Mobile (<900px):** table view disappears entirely (grid only, 2 columns);
  the view toggle is hidden. Bulk pill spans full width minus 16px margins.

### Create / Edit modal
- 14px radius, opaque elevated surface, one blurred scrim. 18px title.
  Fields: Title · Category (Arul only, free-text with suggestions) · media
  file (multi-select on create; "Replace media (optional)" on edit, showing
  the current R2 key in mono) · Published checkbox (create only). Upload area
  reads as a dashed-hairline dropzone: muted glyph + "Drop files or browse".
  Footer right-aligned: ghost Cancel + gold primary. Uploads show inline
  status text (e.g. "File 2 of 5…"); dimension-warning confirms can appear.

### Submissions
- pending/approved/rejected as a segmented control matching the view toggle.
  Table: kind, title, category, date, one always-visible Review action.
  Review modal: 9:16 media preview (video plays), title/category override
  fields, gold Approve + ghost-danger Reject (+ optional reason). Empty state:
  one sentence + nothing else (no giant emoji).

### Category transfer (Arul)
- Three numbered steps with mono labels: "01 · Source" (category select) →
  "02 · Pick" (same card-grid language as wallpapers grid, select-all +
  count) → "03 · Target" (free-text with suggestions + Move button + per-item
  result report). Failed thumbnail loads must render a neutral placeholder
  tile with a ▶ glyph — never a raw broken-image gray box (visible today in
  screenshot 14).

### Sidebar + mobile drawer
- Brand block: "HSR" 16px with a short gold underline, "UNIFIED CMS" 10px
  tracked micro-label. Groups: OVERVIEW (Dashboard) · PAKIZA (Wallpapers,
  Ringtones, Submissions, App config) · ARUL (Wallpapers, Submissions,
  Category transfer, App config). Active item: 2px gold left bar + warm-white
  text on `#1d191d` — not the current blue filled pill. Sign out pinned to the
  bottom. Mobile: hamburger → drawer with the same content, Sign out pinned to
  the drawer's bottom edge (current drawer has a dead-space gap — fix).

### Login
- Centered 380px card on the warm base; "HSR CMS" + one gold accent bar;
  username + password; full-width gold submit. First impression — make it
  exact.

### Config
- Labeled sections; JSON textareas in mono on an inset `#100e10` panel;
  support-email + min-version text fields; gold "Save & rebuild" + ghost
  "Rebuild now".

### Ringtones (Pakiza)
- Same table language as wallpapers minus thumbnails/category: ♪ mark, title,
  status dot, date, row actions. Same create/edit modal pattern with a single
  audio file.

## Anti-patterns (do NOT do these)

- Glass-on-glass frosted stacking (the current design's main flaw).
- Gold as a background/fill on anything larger than a button.
- Bootstrap stat cards (colored icon circles, four identical tiles).
- Hover-ONLY critical actions (touch/keyboard users lose them).
- Bouncy springs, staggered list entrances, parallax — this is a daily tool;
  animation slower than ~220ms is friction.
- Literal religious iconography in the chrome (lamps, domes, lotuses, etc.).

## Out of scope (do not design)

Command palette, density toggle, video hover-scrub, drag-to-reorder, light
mode, user management (single operator), server-side pagination.

---

## Appendix — implementation handoff notes (carry into the Claude Code bundle)

The production app is server-rendered **Hono JSX on Cloudflare Workers**: one
CSS template string + a few vanilla-JS string constants in `cms/src/ui.tsx`,
page JSX in `cms/src/pages/*.tsx`, HTMX for modal content loading. No client
framework, no build step, no external assets beyond HTMX — fonts must be
system-stack. The implementation must preserve, byte-exact: all `data-*`
behavioral attributes (`data-upload-form/-kind/-presign/-slot/-required/
-upload-status/-upload-error`, `data-listview/-page/-search/-filter="N"
(N = column index)/-page-size/-empty-filtered`, `data-grid/-grid-id`,
`data-bulk-id/-all/-bar/-count/-act`, `data-view`, `data-dialog-target/-close`,
`data-confirm`, `data-nav-toggle/-close`, `data-select-all/-selected-count/
-transfer-go/-pickscope`, `hx-get/hx-target/hx-swap`); all form field names
(`title`, `category`, `key_main`, `mime_main`, `id_main`, `items_json`,
`is_published`, `ids`, `bulk_action`, `username`, `password`) and form
actions; script-queried classes (`.tablewrap`, `.pager`, `.filtered-out`,
`.paged-out`, `th.sortable[data-type][data-dir]`, `tbody tr[data-id]`); the
native `<dialog>` modals; and the 52-test suite
(`cd cms && npx tsc --noEmit && npx vitest run`). Deploy stays manual
(`npx wrangler deploy`, owner-run).
