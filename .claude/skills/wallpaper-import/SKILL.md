---
name: wallpaper-import
description: Clean the generator watermark (Gemini sparkle or Veo text) from a folder of live wallpapers and import them into the Arul CMS (R2 + Neon + catalog) under a given category. Use whenever the user has a new folder of live wallpapers (.mp4) to add.
---

# Live wallpaper import — de-watermark + push to CMS

**ALWAYS ask the user first (never assume):**
1. The **folder path** holding the `.mp4` live wallpapers.
2. The **category** — one of: amman · ayyappan · murugan · perumal · sivan · temples.

Tooling + secrets: `ROOT = c:/Anish/arul-import`; content-import scripts under `c:/Anish/Arul/tools/content-import`; secrets in `c:/Anish/Arul/workers/.dev.vars`.

## Two watermarks, two removers — never guess which
Sources come from more than one generator and the removers are **not interchangeable**:

| watermark | where | remover |
| --- | --- | --- |
| **Gemini sparkle** (Flash/Omni image-to-video) | fixed box, `wm-model.json` — output x795–935, y1595–1735 | `dewatermark.py` — un-blend the alpha + inpaint its edge ring |
| **Veo text** ("Veo") | source x682–705, y1253–1264 (bottom-right), `veo-model.json` | crop the bottom strip off, then upscale back to spec |

**Applying the Gemini remover to a non-Gemini file is destructive, not a no-op.** It divides by `(1-alpha)` at that fixed box, so with no sparkle there it **burns a black star into clean artwork**. That shipped-quality bug hit a whole 10-file Veo batch on 2026-07-31 (9 of 10 ruined, caught only by looking). The Veo crop is the safe direction: on a Gemini file it merely fails to remove the sparkle, which the spot-check catches.

`clean-batch.mjs` therefore **routes every file by measurement** (`wm-probe.py`, shape-correlation against both glyph templates — scoring brightness alone false-fires on busy artwork). Thresholds and their calibration: `ROOT/wm-probe-calibration.md`. Don't hand-force `--mode` unless you have already proven the batch.

## Steps (run in order; STOP and report on any failure)
0. **Archive check** — `cd c:/Anish/Arul/tools/content-import && node archive-check.mjs <srcDir>`.
   The masters under ROOT were pruned once they were confirmed in the library, so
   `archive-index.json` is the only record that a clip was ever staged. A `RE-DOWNLOAD` or
   `NEAR-DUP` hit tells you which — and whether it shipped, or **shipped and had its row
   deleted** (3 Ayyappan tigers did). Re-importing one of those needs a reason, not a re-run.
   The index is *not* redundant with step 5: `refhashes.json` only knows what is live now.
1. **Probe** every `.mp4` (dims + duration). **Standard source = 720×1280** — both watermark models are positioned in that space, so any other size misplaces them. Exclude off-size files and tell the user to re-export at 720×1280. Duration is not enforced; short clips are fine.
2. **Title offset:** find the highest existing number so labels never collide, and start at `N+1`:
   ```bash
   cd c:/Anish/Arul/workers && node tools/prod-query.mjs \
     "SELECT max((regexp_match(title,'^<Cat> ([0-9]+)$'))[1]::int) FROM wallpapers WHERE category='<category>'"
   ```
   `prod-query.mjs` is SELECT-only and reads the connection string from `.dev.vars` itself. (Column is `is_published`, not `published`.)
3. **Stage:** clear `ROOT/normalized` + `ROOT/drive`; copy the folder's `.mp4`s into `ROOT/drive` and into `ROOT/masters-<category>` (backup). Both dirs may not exist — the prune removes them once empty; create them.
4. **Clean:** `node ROOT/clean-batch.mjs ROOT/drive` — probes each file, routes it to the matching remover, normalizes to 1024×1824 h264/yuv420p/faststart/no-audio, writes thumbnails + `normalized-manifest.json` (which records the `wm` kind and its scores per file). Read the `probe:` tally it prints — a batch you expected to be one generator coming back mixed means look before continuing. Any file routed `none` gets **no watermark removed** and is flagged; treat it as unverified until step 6.
5. **Dedup:** `cd tools/content-import && node refhash.mjs && node dedup.mjs`. VIEW every flagged pair (new thumb vs the matched existing thumb). dhash flags dark, low-detail frames that share only a silhouette, so most flags are false positives. Keep live-versions of existing stills (established precedent); drop only true re-uploads. Never auto-drop.
6. **Watermark audit (BEFORE import) — measure AND look:**
   - `py ROOT/verify-clean.py ROOT/normalized/*.mp4` — must report 0 flagged. It checks both failure directions: a surviving watermark anywhere in frame, and a star-shaped artifact inside the un-blend box.
   - Then still **VIEW** the bottom-right corner of the outputs (`crop=420:260:604:1564`). The numbers are calibrated, not infallible, and `none` verdicts are a fail-safe that only the eye closes.
7. **Plan:** `node ROOT/plan-batch.mjs <category> <Cat> <startN> ["excludeSrc,…"]` → `import-plan.json` (UUID keys, numbered titles).
8. **QC gate:** `cd tools/content-import && node verify.mjs` — must show 0 failures.
9. **Import:** `node ROOT/import.mjs` — R2 PUT (media + thumbs) → one Neon txn (rows + `content_version` bump) → build-catalog. The rows and the bytes must land together: **an object under `wallpapers/` that no row references is DELETED by the canonical sweep** (a thumb is safe — its key is derived from `full_key`).
10. **Verify:** `node ROOT/e2e-verify.mjs`. Its "titles 1..N" line false-fails for offset batches — confirm titles via a DB query instead; all other checks must pass.

11. **Archive + prune:** `node archive-index.mjs` records the new masters (merges, never
    truncates), then `node archive-prune.mjs` — dry run first — deletes only what the index
    records AND the library confirms, so the ROOT does not grow back to 250 MB.

**Report:** count imported, title range, DB + catalog totals, which remover each file was routed to, and any excluded / dedup-flagged files.

## Adding a new generator's watermark
1. Collect a folder of that generator's clips. Average many frames across many of them (`ROOT/wm-survey.py` pattern) — artwork cancels, anything burned in at a fixed position survives, which both locates the glyph and proves whether any *other* static overlay exists.
2. Build a shape template (`ROOT/build-veo-model.py` is the worked example) and add it to `wm-probe.py`.
3. Calibrate against a known group of every other generator, both directions, and record the numbers in `wm-probe-calibration.md`. Keep the asymmetry: destructive removers must win by a clear margin.
4. Prefer cropping over inpainting where the glyph sits near an edge — nothing is invented, so there is no smudge to judge.
