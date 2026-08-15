# Ringtone imports — the short pipeline

> Read this before a bulk ringtone drop. Wallpapers, prerequisites and the staging ROOT:
> [README.md](README.md). What the two axes mean: CLAUDE.md §1 and §5b.

The twelve wallpaper stages exist because images arrive unlabelled, mis-sized and duplicated.
Ringtone drops are not like that: they arrive already cut to length, and either **foldered by
deity** (`FOLDER_CATEGORY`) or flat with a **hand-maintained per-title map derived from the
lyrics** (`CATEGORY_BY_TITLE`) — so classification is a lookup, not a pipeline, and QC is one
ffprobe.

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
  or title **aborts** rather than guessing: category is the browse axis, so a wrong one files
  the track under the wrong god.
- **Drops are incremental.** Stage 1 reads the live catalog to dedup on normalised title
  and to continue `sort_order` past its high-water mark, so existing users' first screen
  does not re-shuffle. A title collision aborts; override with `--allow-duplicate-titles`
  only after confirming the audio really differs (compare RMS envelopes — near-identical
  names are usually a re-run, occasionally a genuine second recording).
- Stage 2 refuses if any planned `audio_key` already has a row, and ignores a checkpoint
  left over from a previous drop.
- QC: codec and size **abort**; length only **warns** — media-conventions.md says "≤40 s
  recommended", and one over-long track should not block a drop.
- **The importer does not set `deity`.** Its INSERT column list (`ringtones-import.mjs:145`)
  has no such column, so every new drop lands with `deity` null and the app draws the
  CATEGORY's default artwork — the right family of god, never a wrong face. Populating it is
  a follow-up UPDATE; `backfill-deity.sql` is the pattern and is idempotent by construction
  (every statement an absolute assignment). A deity with no bundled PNG degrades the same way,
  so adding one is an insert plus an app release, never a migration.
- `cover_key` stays null and no cover files exist: row art is a **bundled PNG** resolved
  in `deity_art.dart`, never an uploaded object. Do not create `ringtones/covers/…` — nothing
  reads that prefix, so anything put there is unreferenced by construction and the canonical
  sweep deletes it.
- Ringtone objects go up via `wrangler r2 object put --remote` because wrangler is already
  authenticated; the wallpaper importer instead signs S3 requests with the `R2_*` keys in
  `workers/.dev.vars`. Invoke wrangler's JS entrypoint with `node`, never `npx` through a shell:
  a shell re-splits every argument on whitespace and both the filenames and the cache-control
  value contain spaces.
