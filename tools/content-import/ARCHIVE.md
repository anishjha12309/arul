# The staging archive — how the ROOT stays small

> Read when a drop needs checking against clips already handled, or when the staging ROOT has filled up
> with masters again. Pipeline: [README.md](README.md).

Every drop is copied into `drive/` and backed up to `masters-<category>/`, so the ROOT fills with
`.mp4` that R2 already holds. `archive-index.json` (in **this** folder, so it is version-controlled) is
the durable stand-in — a few hundred bytes per clip.

| Script | Role |
|--------|------|
| `archive-index.mjs` | Record every staged clip: dHash, 64-bit content hash, dims/duration/bytes, folders, and the library row it became. **Merges** — never truncates. |
| `archive-check.mjs` | Stage 0 of the pipeline: is this clip one we have already handled? |
| `archive-prune.mjs` | Delete staged media the index records **and** the library confirms. Dry run unless `--apply`. |

- **Why not just `refhashes.json`:** that is rebuilt from the live catalog, so it covers only what
  shipped. A clip rejected at review, failed at QC, or imported and later **deleted in the CMS** leaves
  no trace there, so a re-drop of the same Drive folder looks brand new. The archive is that memory:
  `live=1` in the library · an `id` but not `live` → shipped, then the row was deleted · neither →
  staged, never imported. A `live=0` record may be the only trace left of a clip; re-importing one is a
  decision, not a re-run.
- **Index first, then prune.** `archive-prune.mjs` deletes a file only when its content hash is in the
  index AND that record is `live=1`. Anything unrecorded, or recorded but absent from the library, is
  kept — those are the only copies left.
- **The `live` verdict is stamped at index time, on purpose.** A raw master is watermarked 720×1280 while
  the shipped thumb comes from the *cleaned* 1024×1824 clip (the Veo path crops 40 bottom rows first),
  so a raw-vs-shipped dHash is not like-for-like. The builder re-extracts the frame under each cleaning
  geometry — which needs the media, so it cannot be redone after a prune. Re-running it preserves
  existing verdicts.
- Category never narrows the match: review legitimately re-files a clip into another category.
- **Unlinking can fail silently** — a prune once reported every deletion done while every file with a
  U+2026 ellipsis in its name (Drive truncates long generator names) stayed on disk. `archive-prune.mjs`
  re-stats each path after unlinking and prints failures at the end, where they cannot scroll away.
- Stage 0 catches a re-drop byte-exactly by hash, and perceptually only within `archive-check.mjs`'s
  default Hamming `T = 8`.
