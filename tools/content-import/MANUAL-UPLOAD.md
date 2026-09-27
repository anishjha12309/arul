# Hand-off path — files the operator uploads through the CMS by hand

> Read when a drop is encoded locally but pushed through `api.hsrutility.com/admin` instead of
> `import.mjs`. Scripted import: [README.md](README.md).

```bash
node verify-folder.mjs <dir>     # MUST pass before uploading — see "All or nothing"
node cms-watch.mjs               # tail hsr-cms + arul-api; --report to summarise
```

## Name each file as the title you want

The CMS titles every row from its file's stem, prettified — there is no title field and no per-batch
numbering (numbered "Murugan 1…N" titles were unsearchable). Renaming happens one row at a time on the
edit form, so fix names before the upload.

## Batch, don't drip

One batch posts as a single `items_json`: N rows + ONE `content_version` bump + ONE rebuild. Uploading
singly bumps the version and rebuilds the catalog once **per file**.

## All or nothing

Server-side QC runs per file on create, and **one failure rejects the whole batch** — no rows inserted,
every already-uploaded object deleted. That is why `verify-folder.mjs` must be clean first.

## What the CMS gate does NOT check

The CMS's live-wallpaper check enforces the `avc1`/`avc3` sample entry, `width%128==0`, `height%32==0`,
the 1088×1920 bound and the size cap. It does **not** check `pix_fmt` or an audio stream, so local QC is
the only gate for both:

- **`yuvj420p` (full JPEG range) ships washed out.** `-pix_fmt yuv420p` alone does not convert a
  full-range source — the chain needs `out_range=tv` *and* a trailing `format=yuv420p`
  ([../../docs/media-conventions.md](../../docs/media-conventions.md)). `fix.mjs` repairs a shipped clip
  in place (same R2 key, no DB change).
- Live wallpapers must carry **no audio stream** — social and phone sources almost always do.

## Reading the watcher

- The presigned **PUT is browser→R2 direct** and appears in NO Worker log; if bytes fail to land, read
  the browser's Network tab.
- **A QC rejection is not logged** — the handler redirects `302 …/new?err=…`, so the reason shows only in
  the CMS's red banner. A silent tail plus a red banner is a rejection, not a broken watcher.
- **`wrangler tail` sessions expire and the CLI exits 0**, which reads as a clean shutdown and hides the
  upload. `cms-watch.mjs` respawns and says so loudly, but can still miss a create POST in its restart
  gap. **Confirm landings in the DB, never from tail silence.**

## After the batch

- Rows landed: `SELECT count(*) FROM wallpapers WHERE created_at > '<today>'`.
- **Read catalog freshness with a `?v=` param**, not a `no-cache` header: a `Cache-Control: no-cache` GET
  of a page still returns `cf-cache-status: HIT` off a stale edge copy. An unversioned read looks like a
  failed rebuild.
- Posters are captured **in the browser** at upload time and PUT to the derived
  `thumbs/<category>/<uuid>.jpg`; never upload thumbs by hand. Gaps are fillable from the CMS's missing
  thumbnails page.
- **Uploaded objects with no row are orphans** — the canonical sweep deletes them, but not on the hour:
  the daily pass is the unconditional one and a 12 h grace protects anything younger
  ([../../docs/cron.md](../../docs/cron.md)), so an abandoned modal strands bytes for at least 12 h.
