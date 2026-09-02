---
name: content-ops
description: Arul content/catalog operations — publish, rebuild, verify, bulk import/replace wallpapers, orphan sweeps. Use when content isn't showing, catalog is stale, or wallpapers must be added/replaced in bulk.
---

# Content Ops

**Primary authoring = the unified CMS** `https://api.hsrutility.com/admin` (Arul pages under
`/admin/arul/…`) — row write and version bump in ONE transaction, then the rebuild fires in the
background and self-heals via the cron. There is no purge anywhere; `?v=` does that job. Prefer the
CMS; go direct only for bulk jobs. It is a **separate worker (`hsr-cms`) in a separate repo**
(`c:\Anish\Unified CMS`); **this repo's worker has no `/admin`**.

Two scopes: **wallpapers** and **ringtones**. Ringtone audio lives at
`ringtones/<category>/<uuid>.mp3`. Ringtones have **no cover art in R2**: `cover_key` is null on every row,
the CMS deliberately mints no cover target, and the row art is a PNG BUNDLED IN THE APP, picked by
the row's `deity`. **Never upload anything under `ringtones/covers/…`** — it lands inside the swept
`ringtones/` prefix with no row that can reference it, so `sweep-canonical` deletes it 12 h later,
and a handful of objects sits under the 25-deletion floor so the blast-radius failsafe will not save
it.

**Set `deity` on every ringtone you insert** (free text; the slugs with art are in
`lib/features/ringtones/presentation/deity_art.dart`). Leaving it null is not fatal — the app falls
back to the category's art — but a `perumal` track then shows generic Vishnu instead of Venkateswara.
Backfill/reference SQL: `tools/content-import/backfill-deity.sql`, which is idempotent and safe to
re-run after an import.

The ringtones tab is LIVE. Ringtone categories are NOT the wallpaper ones — five deities plus
`others`, and no `temples`. A published ringtone reaches users exactly like a wallpaper does. **Bulk drops go through
`tools/content-import/ringtones-plan.mjs` → `ringtones-import.mjs`**, not the CMS one-at-a-time
form. They are incremental: the plan script dedups on title against the live catalog and continues
`sort_order` past its high-water mark, so a re-run aborts rather than doubling the list.

## Manual rebuild / check
```bash
API=https://arul-api.hsrutility.com
CDN=https://arul-cdn.hsrutility.com

curl -X POST $API/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
curl -s $CDN/catalog/version.json                            # content_version + built_at
curl -s "$CDN/catalog/wallpapers/all_1.json?v=<version>"
curl -s "$CDN/catalog/ringtones/all_1.json?v=<version>"      # read BOTH — a rebuild can succeed
                                                             # for one scope and fail for the other
```
A zero-row scope still writes an explicit empty `all_1.json` (`total: 0`), so a 404 here means that
scope FAILED to build — never "no content". Both scopes are populated: an unexpectedly empty
`total: 0` is itself a finding, check the DB count before shrugging.

Read the CDN with **GET, never `curl -I`** — on this zone a HEAD returns `cf-cache-status: DYNAMIC`
even for an object a GET reported `HIT` one second earlier, so HEAD is not a readout of cache state
at all and reads exactly like a broken Cache Rule.

Stale content is never a cache problem: rebuild, never purge. Cache behaviour, the two Cache Rules
and that measurement trap are in `docs/caching.md`.

## Counting what is actually in the DB
```bash
cd workers
node tools/prod-query.mjs "SELECT category, count(*) FROM wallpapers WHERE is_published GROUP BY 1 ORDER BY 1"
```
`prod-query.mjs` is SELECT-only and reads the connection string from `.dev.vars`. The column is
**`is_published`**, not `published` — and `wrangler kv key list --namespace-id <prod-id>` reads a
*local* namespace and returns `[]` unless you add `--remote`.

## Bulk import / replace
`tools/content-import/` is the pipeline (stages under `c:/Anish/arul-import/`). The import stages
stamp `public, max-age=31536000, immutable`; `fix.mjs` re-PUTs bare. The shape of any bulk job:

1. Re-encode locally to `docs/media-conventions.md` — live MP4 **must** be 1024×1824.
2. PUT to R2 under `wallpapers/<category>/<uuid>.<ext>`, plus `thumbs/<category>/<uuid>.jpg` for every
   live clip — the poster is what the feed paints first, and `thumbs/` is swept like the other two.
3. ONE Neon transaction: insert/replace rows **and** `content_version = content_version + 1`.
   Map per asset: key→`full_key` · image/video→`type` static/live · **category→category** (the browse
   axis) · title · dims→width/height · bytes. Leave `duration_ms` null unless ffprobe returns a real
   value, and leave `sort_order` alone — only ringtones set it, and nothing reads it for feed order.
   Order is the ORDER BY in `build-catalog` alone ([docs/browse.md](../../../docs/browse.md)); a bulk
   import lands tied on `created_at` and is separated by its random v4 `id`, which is what stops one
   category owning the first screen.
4. Rebuild the catalog; DB, catalog and R2 counts must agree, with all 6 categories present.
   Count the DB with `prod-query.mjs` (above), the catalog with `total` from `all_1.json`.
5. Replaced objects are swept once no row references them — never immediately: a 12 h grace protects
   anything younger, and the sweep itself is on-change hourly plus unconditional at 21:30 UTC.

⚠ **Objects without a DB row are DELETED by the canonical sweep.** Publish rows in the same
transaction that puts the bytes in reach of it. The bucket's `catalog/catalog.json` (the original
one-time import manifest) sits outside the swept prefixes and survives; the app never reads it.

## Orphan sweeps (manual)
```bash
curl -X POST $API/internal/sweep-canonical   -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
curl -X POST $API/internal/sweep-submissions -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
```
`sweep-canonical` covers **three** prefixes — `wallpapers/`, `ringtones/` and `thumbs/` — keeping an
object only while a row references it. `thumbs/` is the dangerous one: no column stores a poster key,
so its references are DERIVED from `full_key`, and a poster whose wallpaper row is gone is deleted.
It never touches `catalog/` or `user/`.
On the cron it runs on-change hourly and unconditionally at 21:30 UTC; `sweep-submissions` runs daily
only. See `docs/cron.md`.
