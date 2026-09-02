# content-import — bulk wallpaper import pipeline

Batch importer for adding wallpapers (static **and** live) to the Arul R2 bucket + Neon DB.
The original catalogue came from an external process; this is the pipeline that replaced it.

It handles the things the CMS one-at-a-time upload does not: **dedup against existing
content**, **vision classification** into the six categories, a **visual review/correction
step**, and a **full media-convention QC gate**. ("The CMS" = the unified CMS worker at
`api.hsrutility.com/admin`, a separate repo checked out at `c:\Anish\Unified CMS`.)

## Prerequisites

- **Node 20+**, **ffmpeg + ffprobe** on PATH.
- **sharp** — borrowed from the unified CMS repo's `node_modules` (`c:/Anish/Unified CMS/`) via
  `createRequire` (no separate install). **Requires that sibling repo to be checked out** — the
  in-repo `cms/` this used to borrow from is gone.
- **aws4fetch + postgres** — `npm i aws4fetch postgres` inside the staging ROOT: `import.mjs` needs both,
  `fix.mjs` only aws4fetch, `ringtones-import.mjs` only postgres — which is why it runs FROM ROOT, not from here.
- Secrets read at runtime from `workers/.dev.vars` (`R2_*`, `DATABASE_URL`, `CATALOG_BUILD_SECRET`) — never hardcoded.

## Staging ROOT

Scripts assume a scratch working dir **outside the repo** (default `c:/Anish/arul-import/`)
holding `drive/` (the raw input) and where all intermediates + `node_modules` live. Media
is never committed. Moving ROOT is not one edit: most scripts carry a `ROOT` const, but `probe.mjs` and
`refhash.mjs` hardcode the path inline, `ringtones-*.mjs` read `process.env.ROOT`, `archive-*.mjs` take `--root`.

## Media conventions enforced (docs/media-conventions.md)

- **Static** → 1080×1920 JPEG, ≤10 MB.
- **Live** → 1024×1824 H.264 **yuv420p** (limited range), faststart (moov<mdat), **no audio**,
  **≤15 MB**, **≤10 s** (normalize auto-trims; the cut is blind, so review anything it flags
  `trimmed:<n>s`), `w%128==0 && h%32==0`, fits the 1088×1920 hw-decoder cap, non-black first frame.
  Encoder settings and WHY they differ for upscaled vs native sources: [../../docs/media-conventions.md](../../docs/media-conventions.md).

## Pipeline order

| # | Script | Role |
|---|--------|------|
| 0 | `archive-check.mjs` | check the drop against `archive-index.json` before the transcode (it still extracts one frame per clip) — catches clips already staged once, including ones imported and later deleted |
| 1 | `probe.mjs` | ffprobe every input; collapse byte-exact dupes → `inventory.json` |
| 2 | `refhash.mjs` | perceptual-hash (dHash) every item in the LIVE published catalog — statics from `full_key`, live clips from their `thumbs/` poster → `refhashes.json`. Unpublished rows and orphaned objects are invisible to it; that gap is what step 0 covers |
| 3 | `normalize.mjs` | transcode to spec (statics→JPG, videos→mp4 + a thumb seeked at 1 s, 640 wide — NOT frame 0, which is the frame `verify.mjs` luma-checks) → `normalized/`, `normalized-manifest.json` |
| 4 | `dedup.mjs` | dHash new items vs existing + intra-batch; flag likely dups → `dedup-manifest.json` |
| 5 | `chunk.mjs` | split into batches for the vision classifiers → `classify-batches/` |
| — | *(vision agents)* | classify each `classify-batches/batch-N.json` per `classify-guide.md`, returning `{category, confidence, reason, title}` per item. **Merge the six results BY HAND into one `classifications.json` keyed by `base`** — `merge.mjs` reads that file and never globs the batches. A missing or out-of-vocab answer silently falls back to the dup's category, else `temples`; `unclassified (fallback used)` is the only signal |
| 6 | `merge.mjs` | combine dedup + classifications → `review-data.json` |
| 7 | `buildreview.mjs` | self-contained local `review.html` — thumbnails + category dropdowns + "copy corrections" |
| — | *(human review)* | open `review.html`, correct categories / SKIP items, paste JSON → `corrections.json` |
| 8 | `buildplan.mjs` | apply corrections; assign fresh UUID keys (video thumb key = clip key stem) → `import-plan.json` |
| 9 | `import.mjs` | **live write:** PUT to R2 → one Neon txn (rows + `content_version` bump) → `build-catalog` → verify. Records `import-result.json` (ids + keys) for rollback |
| 10 | `verify.mjs` | QC the plan's LOCAL `normalized/` files against all conventions (dims, codec, pix_fmt, faststart, audio, size, frame-0). It never reads R2, so run it as the GATE before step 9 — after the import it only re-checks what you already shipped |
| 11 | `fix.mjs` | re-encode live clips whose `pix_fmt` is not `yuv420p` (full-range `yuvj420p` → `yuv420p`) and overwrite the same R2 key. `pix_fmt` is its ONLY test — a dims/audio/faststart/size failure is invisible to it — and the re-PUT drops the year-long `cache-control` `import.mjs` stamped |

## Ringtones — a separate, much shorter pipeline

Two scripts, not twelve: ringtone drops arrive already cut to length and already named after the
deity, so classification is a lookup and QC is one ffprobe. **Read [RINGTONES.md](RINGTONES.md)
before a bulk ringtone drop** — the incremental-dedup contract, the two source layouts, and why a
new drop lands with `deity` null all live there.

## The staging archive

ROOT masters are pruned once the library confirms them; `archive-index.json` is the ~40 KB record
replacing them, and what step 0 checks a drop against. `archive-index.mjs` builds and merges it,
`archive-prune.mjs` deletes confirmed masters (dry run unless `--apply`) — index first, prune second,
or the prune has nothing to check against. **Read [ARCHIVE.md](ARCHIVE.md) when de-duplicating a drop,
or when ROOT fills up.** Uploading by hand through the CMS skips every gate above (`verify-folder.mjs`
is the stand-in QC, `cms-watch.mjs` tails both workers): **read [MANUAL-UPLOAD.md](MANUAL-UPLOAD.md)
first** — the presigned PUT goes browser→R2 and appears in no Worker log, so tail silence proves nothing.

## Notes

- **Dedup is perceptual**, not byte-hash: existing R2 images were re-encoded, so their bytes
  never match a fresh source. dHash + Hamming distance catches the "already added" ones.
- `import.mjs` uploads R2 **before** the DB write, so a failed insert only leaves benign
  orphans (swept by the hourly cron). The DB write is one transaction.
- **Rollback:** `import-result.json` lists every inserted row id + R2 key — delete rows,
  delete objects, rebuild.
- `fix.mjs` overwrites existing keys, so it needs **no** DB/catalog change.
