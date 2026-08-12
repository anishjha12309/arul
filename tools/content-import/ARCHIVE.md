# The staging archive — how the ROOT stays small

> Read this when a drop needs checking against clips already handled, or when the staging
> ROOT has filled up with masters again. Pipeline itself: [README.md](README.md).

The ROOT accumulates masters: every drop is copied into `drive/` and backed up to
`masters-<category>/`, so it grew to ~250 MB of `.mp4` that R2 already holds.
`archive-index.json` (in **this** folder, so it is version-controlled) is the durable
stand-in — ~40 KB for 164 clips, about 200 bytes each.

| Script | Role |
|--------|------|
| `archive-index.mjs` | record every staged clip: dHash, 64-bit content hash, dims/duration/bytes, folders, and the library row it became. **Merges** — never truncates. |
| `archive-check.mjs` | stage 0 of the pipeline: is this clip one we have already handled? |
| `archive-prune.mjs` | delete staged media that the index records **and** the library confirms. Dry run unless `--apply`. |

- **Why it is not just `refhashes.json`.** That is rebuilt from the live catalog, so it
  covers what shipped and nothing else. A clip that was rejected at review, failed QC, or
  was imported and later **deleted from the CMS** leaves no trace in the catalog — so on the
  next re-drop of the same Drive folder it looks brand new. The archive is that memory:
  `live=1` in library · `id` but not `live` → shipped then the row was deleted · neither →
  staged but never imported.
- **Order matters: index, then prune.** `archive-prune.mjs` deletes a file only when its
  content hash is in the index AND that record is `live=1`. Anything unrecorded, or recorded
  but absent from the library, is kept — those are the only copies left.
- **The `live` verdict is stamped at index time, on purpose.** A raw master is watermarked
  720×1280 while the shipped thumb comes from the *cleaned* 1024×1824 clip, and the Veo path
  crops 40 bottom rows first, so a raw-vs-shipped dHash is not like-for-like. The builder
  re-extracts the frame under each cleaning geometry to settle it — which needs the media,
  so it cannot be redone after a prune. Re-running the builder preserves existing verdicts.
- Category is **not** used to narrow the match: the review step legitimately re-files a clip
  into another category, and restricting by folder reported those as missing.
- **Verify deletes, don't assume them.** The first prune run reported 182 deletions but left
  38 files on disk — every one with a U+2026 ellipsis in its name (Drive truncates long
  generator names). `archive-prune.mjs` now re-stats each path after unlinking and prints
  failures at the end, where they cannot scroll out of view.

## Clips kept back

Nine clips are **not** in the library and are the only copies, so the prune keeps them:
five perumal and one amman that were staged but never imported, and three Ayyappan tigers
(9 · 10 · 14) that shipped and then had their rows deleted. Re-importing one of those is a
decision, not a re-run.
