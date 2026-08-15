# content-import — bulk wallpaper import pipeline

One-time / batch importer for adding wallpapers (static **and** live) to the Arul R2
bucket + Neon DB. The repo previously had no importer (the original 428 came from an
external process); this is that pipeline, built for the Drive drop of 2026-07-16.

It handles the things the CMS one-at-a-time upload does not: **dedup against existing
content**, **vision classification** into the six categories, a **visual review/correction
step**, and a **full media-convention QC gate**. ("The CMS" = the unified CMS worker at
`api.hsrutility.com/admin`, a separate repo checked out at `c:\Anish\Unified CMS`.)

## Prerequisites

- **Node 20+**, **ffmpeg + ffprobe** on PATH.
- **sharp** — borrowed from the unified CMS repo's `node_modules` (`c:/Anish/Unified CMS/`) via
  `createRequire` (no separate install). **Requires that sibling repo to be checked out** — the
  in-repo `cms/` this used to borrow from was deleted 2026-07-20.
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
  ≤50 MB, `w%128==0 && h%32==0`, fits the 1088×1920 hw-decoder cap, non-black first frame.

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

The twelve wallpaper stages exist because images arrive unlabelled, mis-sized and duplicated.
Ringtone drops are not like that: they arrive already cut to length, and either **foldered by
deity** (`FOLDER_CATEGORY`) or flat with a **hand-maintained per-title map derived from the
lyrics** (`CATEGORY_BY_TITLE`) — so classification is a lookup, not a pipeline, and QC is one
ffprobe. Two scripts:

| # | Script | Role |
|---|--------|------|
| 1 | `ringtones-plan.mjs` | ffprobe + QC · classify · dedup vs the LIVE catalog · UUID keys · interleaved `sort_order` → `ringtone-import-plan.json`. Read-only, safe to re-run. |
| 2 | `ringtones-import.mjs` | **live write:** R2 PUT → one Neon txn (rows + `content_version`) → `build-catalog` → verify. `--dry-run` prints only. Checkpointed, so a partial failure re-runs cheaply. |

```bash
SRC=c:/path/to/drop node ringtones-plan.mjs      # review the printed plan first
cp ringtones-import.mjs c:/Anish/arul-import/ && cd c:/Anish/arul-import && node ringtones-import.mjs
```

- **Two source layouts, auto-detected.** Subfolders → category from `FOLDER_CATEGORY`
  (how the drive drops arrive: `Govinda/`, `Murugan/`, `Shiv ji/`); a flat folder →
  category from `CATEGORY_BY_TITLE`. The two are alternatives, not additive — subfolders
  holding audio win and loose files at the top of `SRC` are then ignored. An unmapped folder
  or title **aborts** rather than guessing — category drives the app's medallion motif.
- **Drops are incremental.** Stage 1 reads the live catalog to dedup on normalised title
  and to continue `sort_order` past its high-water mark, so existing users' first screen
  does not re-shuffle. A title collision aborts; override with `--allow-duplicate-titles`
  only after confirming the audio really differs (compare RMS envelopes — near-identical
  names are usually a re-run, occasionally a genuine second recording).
- Stage 2 refuses if any planned `audio_key` already has a row, and ignores a checkpoint
  left over from a previous drop.
- QC: codec and size **abort**; length only **warns** — media-conventions.md says "≤40 s
  recommended", and one over-long track should not block a drop.
- `cover_key` is always null: the app DRAWS its kolam medallion. No cover art is uploaded.
- Ringtone objects go up via `wrangler r2 object put --remote` because wrangler is already
  authenticated; the wallpaper importer instead signs S3 requests with the `R2_*` keys in
  `workers/.dev.vars`. Invoke wrangler's JS entrypoint with `node`, never `npx` through a shell:
  a shell re-splits every argument on whitespace and both the filenames and the cache-control
  value contain spaces.

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
