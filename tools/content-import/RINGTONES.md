# Ringtone imports — the short pipeline

> Read before a bulk ringtone drop. Prerequisites and the staging ROOT: [README.md](README.md). What
> the two axes mean: [../../docs/ringtones.md](../../docs/ringtones.md).

Ringtone drops arrive already cut to length and either **foldered by deity** (`FOLDER_CATEGORY`) or flat
with a **hand-maintained per-title map derived from the LYRICS** (`CATEGORY_BY_TITLE`) — never from file
names, which misfiled a sixth of one drop. So classification is a lookup and QC is one ffprobe.

| # | Script | Role |
|---|--------|------|
| 1 | `ringtones-plan.mjs` | ffprobe + QC · classify · dedup vs the LIVE catalog · UUID keys · interleaved `sort_order` → `ringtone-import-plan.json`. Read-only, safe to re-run. |
| 2 | `ringtones-import.mjs` | **live write:** R2 PUT → one Neon txn (rows + `content_version`) → `build-catalog` → check. `--dry-run` prints only. Checkpointed, so a partial failure re-runs cheaply. |

```bash
SRC=c:/path/to/drop node ringtones-plan.mjs      # review the printed plan first
cp ringtones-import.mjs c:/Anish/arul-import/ && cd c:/Anish/arul-import && node ringtones-import.mjs
```

- **Two source layouts, auto-detected, never additive:** subfolders holding audio win (category from
  `FOLDER_CATEGORY`, e.g. `Govinda/`, `Murugan/`, `Shiv ji/`) and loose files at the top of `SRC` are
  then ignored; a flat folder takes `CATEGORY_BY_TITLE`. An unmapped folder or title **aborts** rather
  than guessing — a wrong category files the track under the wrong god.
- **Drops are incremental.** Stage 1 reads the live catalog to dedup on normalised title and to continue
  `sort_order` past its high-water mark, so existing users' first screen does not re-shuffle. A title
  collision aborts; override with `--allow-duplicate-titles` only after confirming the audio differs
  (compare RMS envelopes — near-identical names are usually a re-run).
- Stage 2 refuses if any planned `audio_key` already has a row, and ignores a checkpoint left from a
  previous drop.
- QC: codec and size **abort**; length only **warns** — the ≤40 s figure is a recommendation, and one
  long track should not block a drop.
- **The importer does not set `deity`** — its INSERT has no such column, so a new drop lands with `deity`
  null and the app draws the CATEGORY's default art: the right family of god, never a wrong face.
  Populate it with a follow-up UPDATE; `backfill-deity.sql` is the pattern (idempotent — every statement
  an absolute assignment). A deity with no bundled WebP degrades the same way, so adding one is an
  insert plus an app release, never a migration.
- `cover_key` stays null — never create `ringtones/covers/…` ([../../docs/ringtones.md](../../docs/ringtones.md)
  §Row art).
- Ringtone objects go up via `wrangler r2 object put --remote` (wrangler is already authenticated); the
  wallpaper importer signs S3 requests with the `R2_*` keys in `workers/.dev.vars` instead. Invoke
  wrangler's JS entrypoint with `node`, never `npx` through a shell: a shell re-splits every argument on
  whitespace, and both the filenames and the cache-control value contain spaces.
