---
name: wallpaper-import
description: Clean the Google Gemini watermark from a folder of live wallpapers and import them into the Arul CMS (R2 + Neon + catalog) under a given category. Use whenever the user has a new folder of live wallpapers (.mp4) to add.
---

# Live wallpaper import — de-watermark + push to CMS

**ALWAYS ask the user first (never assume):**
1. The **folder path** holding the `.mp4` live wallpapers.
2. The **category** — one of: amman · ayyappan · murugan · perumal · sivan · temples.

Tooling + secrets: `ROOT = c:/Anish/arul-import`; content-import scripts under `c:/Anish/Arul/tools/content-import`; secrets in `c:/Anish/Arul/workers/.dev.vars`. Watermark model = `ROOT/wm-model.json`.

## Steps (run in order; STOP and report on any failure)
1. **Probe** every `.mp4` (dims + duration). **Standard source = 720×1280.** Any other size will misplace the fixed watermark mask (black-star artifact + leftover sparkle) — exclude those and tell the user to re-export them at 720×1280. Duration is not enforced; short clips are fine.
2. **Title offset:** find the highest existing number so labels never collide, and start at `N+1`:
   ```bash
   cd c:/Anish/Arul/workers && node tools/prod-query.mjs \
     "SELECT max((regexp_match(title,'^<Cat> ([0-9]+)$'))[1]::int) FROM wallpapers WHERE category='<category>'"
   ```
   `prod-query.mjs` is SELECT-only and reads the connection string from `.dev.vars` itself.
3. **Stage:** clear `ROOT/normalized` + `ROOT/drive`; copy the folder's `.mp4`s into `ROOT/drive` and into `ROOT/masters-<category>` (backup).
4. **Clean:** `node ROOT/clean-batch.mjs ROOT/drive` — de-watermarks (dewatermark.py: hybrid un-blend + edge inpaint), normalizes to 1024×1824 h264/yuv420p/faststart/no-audio, writes thumbnails + `normalized-manifest.json`.
5. **Dedup:** `cd tools/content-import && node refhash.mjs && node dedup.mjs`. VIEW every flagged pair (new thumb vs the matched existing thumb). Keep live-versions of existing stills (established precedent); drop only true re-uploads. Never auto-drop.
6. **Watermark spot-check (BEFORE import):** extract `crop=300:300:704:1500` from a few cleaned outputs and VIEW — confirm no sparkle and no black artifact.
7. **Plan:** `node ROOT/plan-batch.mjs <category> <Cat> <startN> ["excludeSrc,…"]` → `import-plan.json` (UUID keys, numbered titles).
8. **QC gate:** `cd tools/content-import && node verify.mjs` — must show 0 failures.
9. **Import:** `node ROOT/import.mjs` — R2 PUT (media + thumbs) → one Neon txn (rows + `content_version` bump) → build-catalog. The rows and the bytes must land together: **an object under `wallpapers/` that no row references is DELETED by the canonical sweep** (a thumb is safe — its key is derived from `full_key`).
10. **Verify:** `node ROOT/e2e-verify.mjs`. Its "titles 1..N" line false-fails for offset batches — confirm titles via a DB query instead; all other checks must pass.

**Report:** count imported, title range, DB + catalog totals, and any excluded / dedup-flagged files.
