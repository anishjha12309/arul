# Hand-off path — files the operator uploads through the CMS by hand

> Read this when a drop is encoded locally but pushed through `api.hsrutility.com/admin`
> instead of `import.mjs`. Scripted import: [README.md](README.md).

```bash
node verify-folder.mjs <dir>     # MUST pass before uploading — see "all or nothing"
node cms-watch.mjs               # tail hsr-cms + arul-api; --report to summarise
```

## Name the files as the titles you want

The uploader ships a per-file title in `items_json` and the row resolves as
`it.title ?? "<Title field> <i+1>"` (`wallpapers.tsx:994`). **"Derive titles from the file
names" is checked by default**, so the filename stem wins and the Title field is unused —
but it is still `required` by the HTML, so type anything to submit. Name the files
`<Cat> N.mp4`, continuing from `max(<Cat> N)+1` for that category in the DB.

**Do not uncheck it.** Without per-file titles every batch numbers from 1 (`Sivan 1…N`) and
collides with the existing rows.

## Batch, don't drip

One batch posts as a single `items_json`: *"N rows + ONE version bump + ONE rebuild"*
(`wallpapers.tsx:904`). Uploading singly bumps `content_version` and rebuilds the catalog
once **per file**.

## All or nothing

Server-side QC runs per file on create; **one failure rejects the whole batch** — no rows
inserted and every already-uploaded object deleted (`wallpapers.tsx:947-985`). That is why
`verify-folder.mjs` must be clean first: a single bad file costs the entire upload.

## What the CMS gate does NOT check

`verifyLiveWallpaper` (hsr-cms `media-verify.ts`) enforces only stsd fourcc ∈ {avc1, avc3},
`width%128==0`, `height%32==0`, within 1088×1920, and the size cap. It does **not** check
`pix_fmt` or the absence of an audio stream. Both ship silently wrong, so local QC is the
only gate for them:

- **`yuvj420p` (full JPEG range) ships washed out.** `-pix_fmt yuv420p` alone does not
  convert a full-range source — the filter chain needs `out_range=tv` *and* a trailing
  `format=yuv420p`. 7 of 63 files in one drop came out full-range before `clean-batch.mjs` was fixed — that one lives in the staging ROOT (`c:/Anish/arul-import/`),
  outside this repo and outside git. `fix.mjs` repairs it in place (same R2 key, no DB change).
- Live wallpapers must carry **no audio stream** — social/phone sources almost always do.

## Reading the watcher

- The presigned **PUT is browser→R2 direct**. It appears in NO Worker log; if bytes fail to
  land, look at the browser Network tab.
- A **QC rejection is not logged** — the handler redirects `302 …/new?err=…`, so the reason
  shows only in the CMS's red banner. A silent tail plus a red banner is a rejection, not a
  broken watcher.
- **`wrangler tail` sessions expire** and the CLI exits 0, which reads as a clean shutdown.
  An expired tail during an upload is worse than none: the log stays quiet and looks like
  success. `cms-watch.mjs` respawns and says so loudly, but it has still missed a create POST
  during its own restart gap. **Verify landings in the DB, never from tail silence.**

## After the batch

- Rows landed: `SELECT count(*) FROM wallpapers WHERE created_at > '<today>'`.
- **Catalog freshness needs a cache-busting param**, not just a `no-cache` header: a
  `Cache-Control: no-cache` GET of `catalog/wallpapers/all_N.json` still returns
  `cf-cache-status: HIT` off a stale edge copy, while the same URL with `?v=` returns `MISS`.
  An unversioned read looks like a failed rebuild.
- Posters are captured **in the browser** at upload time and PUT to the derived
  `thumbs/<category>/<uuid>.jpg`; never upload thumbs by hand. Gaps are fillable from
  `/admin/arul/wallpapers/thumbnails/missing`.
- **Uploaded objects with no row are orphans** and the canonical sweep deletes anything under
  `wallpapers/` that no row references. Do not expect it on the hour: the `0 * * * *` run is
  skipped unless a catalog scope actually rebuilt, the unconditional pass is the daily
  `30 21 * * *`, and a 12 h grace protects anything younger — so an abandoned modal strands
  bytes for at least 12 h.
