---
name: content-ops
description: Arul content/catalog operations — publish, rebuild, verify, bulk import/replace wallpapers, orphan sweeps. Use when content isn't showing, catalog is stale, or wallpapers must be added/replaced in bulk.
---

# Content Ops

**Primary authoring = the unified CMS** `https://api.hsrutility.com/admin` (Arul pages under
`/admin/arul/…`) — row write + version bump + rebuild + purge atomically. Prefer it; go direct only
for bulk jobs. It is a **separate worker (`hsr-cms`) in a separate repo** (`c:\Anish\Unified CMS`);
**this repo's worker has no `/admin`**.

Two scopes: **wallpapers** and **ringtones**. Ringtone audio lives at
`ringtones/<category>/<uuid>.mp3`, cover art at `ringtones/covers/<category>/<uuid>.jpg`.

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

Read the CDN with **GET, never `curl -I`** — HEAD does not populate Cloudflare's cache and reports
`DYNAMIC` for assets that cache perfectly well, which reads exactly like a broken Cache Rule.

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
`tools/content-import/` is the pipeline (stages under `c:/Anish/arul-import/`; it stamps
`public, max-age=31536000, immutable` on every upload). The shape of any bulk job:

1. Re-encode locally to `docs/media-conventions.md` — live MP4 **must** be 1024×1824.
2. PUT to R2 under `wallpapers/<category>/<uuid>.<ext>`.
3. ONE Neon transaction: insert/replace rows **and** `content_version = content_version + 1`.
   Map per asset: key→`full_key` · image/video→`type` static/live · **category→category** (the browse
   axis) · title · dims→width/height · bytes · rank→`sort_order`. Leave `duration_ms` null unless
   ffprobe returns a real value.
4. Rebuild the catalog; DB, catalog and R2 counts must agree, with all 6 categories present.
   Count the DB with `prod-query.mjs` (above), the catalog with `total` from `all_1.json`.
5. Replaced objects are swept once no row references them.

⚠ **Objects without a DB row are DELETED by the canonical sweep.** Publish rows in the same
transaction that puts the bytes in reach of it. The bucket's `catalog/catalog.json` (the original
one-time import manifest) sits outside the swept prefixes and survives; the app never reads it.

## Orphan sweeps (manual)
```bash
curl -X POST $API/internal/sweep-canonical   -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
curl -X POST $API/internal/sweep-submissions -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
```
`sweep-canonical` covers **both** canonical prefixes — `wallpapers/` and `ringtones/` (audio **and**
covers) — keeping an object only while a row references it. It never touches `catalog/` or `user/`.
On the cron it runs on-change hourly and unconditionally at 21:30 UTC; `sweep-submissions` runs daily
only. See `docs/cron.md`.
