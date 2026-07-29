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

⚠ **The app's ringtones tab is PARKED in v1** — the route is commented out, so publishing ringtones
will NOT make them appear. Publishing is necessary but not sufficient: un-parking is a code change
(`docs/known-issues.md`). The scope, the prefix and the sweep all still run — publish and sweep
ringtones normally, just don't expect a shipped build to show them.

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
scope FAILED to build — not that it is empty. Ringtones is legitimately empty today (0 published),
which is exactly why its tab is parked.

Stale content is never a cache problem: rebuild, never purge. Cache behaviour, the two Cache Rules
and the HEAD-vs-GET measurement trap are in `docs/caching.md`.

## Bulk import / replace
`tools/content-import/` is the pipeline (stages under `c:/Anish/arul-import/`; it stamps
`public, max-age=31536000, immutable` on every upload). The shape of any bulk job:

1. Re-encode locally to `docs/media-conventions.md` — live MP4 **must** be 1024×1824.
2. PUT to R2 under `wallpapers/<category>/<uuid>.<ext>`.
3. ONE Neon transaction: insert/replace rows **and** `content_version = content_version + 1`.
   Map per asset: key→`full_key` · image/video→`type` static/live · **category→category** (the browse
   axis) · title · dims→width/height · bytes · rank→`sort_order`. Leave `duration_ms` null unless
   ffprobe returns a real value.
4. Rebuild the catalog; DB, catalog and R2 counts must agree (614 wallpapers today) with all 6
   categories present.
5. Replaced objects are swept once no row references them.

⚠ **Objects without a DB row are DELETED by the canonical sweep.** Publish rows in the same
transaction that puts the bytes in reach of it. The bucket's `catalog/catalog.json` (the 2026-07-14
import manifest, 428 assets) sits outside the swept prefixes and survives; the app never reads it.

## Orphan sweeps (manual)
```bash
curl -X POST $API/internal/sweep-canonical   -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
curl -X POST $API/internal/sweep-submissions -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
```
`sweep-canonical` covers **both** canonical prefixes — `wallpapers/` and `ringtones/` (audio **and**
covers) — keeping an object only while a row references it. It never touches `catalog/` or `user/`.
On the cron it runs on-change hourly and unconditionally at 21:30 UTC; `sweep-submissions` runs daily
only. See `docs/cron.md`.
