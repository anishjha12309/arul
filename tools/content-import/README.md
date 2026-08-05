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
- **aws4fetch + postgres** — `npm i aws4fetch postgres` inside the staging ROOT (only needed for `import.mjs` / `fix.mjs`).
- Secrets read at runtime from `workers/.dev.vars` (`R2_*`, `DATABASE_URL`, `CATALOG_BUILD_SECRET`) — never hardcoded.

## Staging ROOT

Scripts assume a scratch working dir **outside the repo** (default `c:/Anish/arul-import/`)
holding `drive/` (the raw input) and where all intermediates + `node_modules` live. Media
is never committed. Adjust the `ROOT` const at the top of each script for a new location.

## Media conventions enforced (docs/media-conventions.md)

- **Static** → 1080×1920 JPEG, ≤10 MB.
- **Live** → 1024×1824 H.264 **yuv420p** (limited range), faststart (moov<mdat), **no audio**,
  ≤50 MB, `w%128==0 && h%32==0`, fits the 1088×1920 hw-decoder cap, non-black first frame.

## Pipeline order

| # | Script | Role |
|---|--------|------|
| 1 | `probe.mjs` | ffprobe every input; collapse byte-exact dupes → `inventory.json` |
| 2 | `refhash.mjs` | perceptual-hash (dHash) all existing R2 objects → `refhashes.json` |
| 3 | `normalize.mjs` | transcode to spec (statics→JPG, videos→mp4 + first-frame thumb) → `normalized/`, `normalized-manifest.json` |
| 4 | `dedup.mjs` | dHash new items vs existing + intra-batch; flag likely dups → `dedup-manifest.json` |
| 5 | `chunk.mjs` | split into batches for the vision classifiers → `classify-batches/` |
| — | *(vision agents)* | each batch classified into 6 categories using `classify-guide.md` → `classify-batches/out-N.json` |
| 6 | `merge.mjs` | combine dedup + classifications → `review-data.json` |
| 7 | `buildreview.mjs` | self-contained local `review.html` — thumbnails + category dropdowns + "copy corrections" |
| — | *(human review)* | open `review.html`, correct categories / SKIP items, paste JSON → `corrections.json` |
| 8 | `buildplan.mjs` | apply corrections; assign fresh UUID keys (video thumb key = clip key stem) → `import-plan.json` |
| 9 | `import.mjs` | **live write:** PUT to R2 → one Neon txn (rows + `content_version` bump) → `build-catalog` → verify. Records `import-result.json` (ids + keys) for rollback |
| 10 | `verify.mjs` | QC every imported file against all conventions (dims, codec, pix_fmt, faststart, audio, size, frame-0) |
| 11 | `fix.mjs` | re-encode any non-conformant live video (e.g. full-range yuvj420p → yuv420p) and overwrite the same R2 key in place |

## Ringtones — a separate, much shorter pipeline

The eight wallpaper stages exist because images arrive unlabelled, mis-sized and
duplicated. Ringtone drops are not like that: they arrive cut to length and **named after
the deity**, so classification is a title map and QC is one ffprobe. Two scripts:

| # | Script | Role |
|---|--------|------|
| 1 | `ringtones-plan.mjs` | ffprobe + QC (codec/length/size) · title→category map · UUID keys · interleaved `sort_order` → `ringtone-import-plan.json`. No network, no credentials, safe to re-run. |
| 2 | `ringtones-import.mjs` | **live write:** R2 PUT → one Neon txn (rows + `content_version`) → `build-catalog` → verify. `--dry-run` prints only. Checkpointed, so a partial failure re-runs cheaply. |

- **Add new titles to `CATEGORY_BY_TITLE`** in stage 1 — an unmapped title aborts the plan
  rather than guessing. Category drives the app's medallion motif, so it is not cosmetic.
- `cover_key` is always null: the app DRAWS its kolam medallion. No cover art is uploaded.
- Objects go up via `wrangler r2 object put --remote`, not the S3 API — the R2 S3 keys are
  not on disk anywhere, and wrangler is already authenticated against the account. Invoke
  wrangler's JS entrypoint with `node`, never `npx` through a shell: a shell re-splits every
  argument on whitespace and both the filenames and the cache-control value contain spaces.
- Stage 2 **refuses to run against a non-empty `ringtones` table** — it was written for the
  first import. Drop that guard deliberately (and check for duplicates) for the second.

## Notes

- **Dedup is perceptual**, not byte-hash: existing R2 images were re-encoded, so their bytes
  never match a fresh source. dHash + Hamming distance catches the "already added" ones.
- `import.mjs` uploads R2 **before** the DB write, so a failed insert only leaves benign
  orphans (swept by the hourly cron). The DB write is one transaction.
- **Rollback:** `import-result.json` lists every inserted row id + R2 key — delete rows,
  delete objects, rebuild.
- `fix.mjs` overwrites existing keys, so it needs **no** DB/catalog change.
