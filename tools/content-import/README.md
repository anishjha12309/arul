# content-import — bulk wallpaper import pipeline

Batch importer for wallpapers (static **and** live) into the Arul R2 bucket and Neon. It does what the
CMS upload does not: **dedup against existing content**, **vision classification** into the six
categories, a **visual review/correction step**, and the **full media-convention QC gate**. ("The CMS" =
the unified CMS worker at `api.hsrutility.com/admin`, a separate repo at `c:\Anish\Unified CMS`.)
Ringtones: [RINGTONES.md](RINGTONES.md) · the staging archive: [ARCHIVE.md](ARCHIVE.md) · uploading by
hand through the CMS: [MANUAL-UPLOAD.md](MANUAL-UPLOAD.md).

## Prerequisites

- **Node 20+**, **ffmpeg + ffprobe** on PATH.
- **sharp** is borrowed from the CMS repo's `node_modules` via `createRequire` — that repo must be
  checked out at `c:/Anish/Unified CMS/`.
- **aws4fetch + postgres** — `npm i aws4fetch postgres` inside the staging ROOT: `import.mjs` needs both,
  `fix.mjs` only aws4fetch, `ringtones-import.mjs` only postgres — which is why it runs FROM ROOT.
- Secrets are read at runtime from `workers/.dev.vars` (`R2_*`, `DATABASE_URL`, `CATALOG_BUILD_SECRET`)
  — never hardcoded.

## Staging ROOT

A scratch dir **outside the repo** (default `c:/Anish/arul-import/`) holds `drive/` (the raw input), every
intermediate and `node_modules`. Media is never committed. Moving ROOT is not one edit: most scripts
carry a `ROOT` const, but `probe.mjs` and `refhash.mjs` hardcode the path inline, `ringtones-*.mjs` read
`process.env.ROOT`, and `archive-*.mjs` take `--root`.

## What the gate enforces

Every rule in [../../docs/media-conventions.md](../../docs/media-conventions.md), checked by `verify.mjs`.
`normalize.mjs` trims clips over 10 s BLIND — review anything flagged `trimmed:<n>s` before publishing.

## Pipeline order

| # | Script | Role |
|---|--------|------|
| 0 | `archive-check.mjs` | Check the drop against `archive-index.json` before the transcode — catches clips staged once before, including ones imported and later deleted |
| 1 | `probe.mjs` | ffprobe every input; collapse byte-exact dupes → `inventory.json` |
| 2 | `refhash.mjs` | dHash every item in the LIVE published catalog (statics from `full_key`, live from its `thumbs/` poster) → `refhashes.json`. Unpublished rows and orphans are invisible to it; step 0 covers that gap |
| 3 | `normalize.mjs` | Transcode to spec (statics → JPG, videos → MP4 + a 640-wide thumb seeked at 1 s — NOT frame 0, which `verify.mjs` luma-checks) → `normalized/` |
| 4 | `dedup.mjs` | dHash new items vs existing + intra-batch → `dedup-manifest.json` |
| 5 | `chunk.mjs` | Split into batches for the vision classifiers → `classify-batches/` |
| — | *(vision agents)* | Classify each batch per `classify-guide.md`. **Merge the results BY HAND into one `classifications.json` keyed by `base`** — `merge.mjs` never globs the batches. A missing or out-of-vocab answer silently falls back to the dup's category, else `temples`; `unclassified (fallback used)` is the only signal |
| 6 | `merge.mjs` | Combine dedup + classifications → `review-data.json` |
| 7 | `buildreview.mjs` | Self-contained local `review.html` — thumbnails, category dropdowns, "copy corrections" |
| — | *(human review)* | Correct categories / SKIP items in `review.html`, paste the JSON → `corrections.json` |
| 8 | `buildplan.mjs` | Apply corrections; fresh UUID keys (video thumb key = clip key stem) → `import-plan.json` |
| 9 | `verify.mjs` | QC the plan's LOCAL `normalized/` files against every convention. It never reads R2 — run it as the GATE before step 10 |
| 10 | `import.mjs` | **Live write:** PUT to R2 → one Neon txn (rows + `content_version` bump) → `build-catalog` → check. Writes `import-result.json` (ids + keys) for rollback |
| 11 | `fix.mjs` | Re-encode live clips whose `pix_fmt` is not `yuv420p` and overwrite the same R2 key. `pix_fmt` is its ONLY test, and the re-PUT drops the year-long `cache-control` `import.mjs` stamped; its encoder MUST stay in lockstep with `normalize.mjs` |

## Notes

- **Dedup is perceptual**, not byte-hash: existing R2 images were re-encoded, so their bytes never match
  a fresh source. dHash + Hamming distance catches the "already added" ones.
- `import.mjs` uploads R2 **before** the DB write, so a failed insert leaves only orphans, which the
  daily canonical sweep reclaims once past its grace. The DB write is one transaction.
- **Rollback:** `import-result.json` lists every inserted row id and R2 key — delete rows, delete
  objects, rebuild with a version bump.
- `fix.mjs` overwrites existing keys, so it needs **no** DB or catalog change.
