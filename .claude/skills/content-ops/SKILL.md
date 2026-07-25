---
name: content-ops
description: Arul content/catalog operations — publish, rebuild, verify, bulk import/replace wallpapers, orphan sweeps. Use when content isn't showing, catalog is stale, or wallpapers must be added/replaced in bulk.
---

# Content Ops

**Primary authoring = the unified CMS** `https://api.hsrutility.com/admin` (Arul pages under
`/admin/arul/…`) — row write + version bump + rebuild + purge atomically. Prefer it; go direct only
for bulk jobs. It is a **separate worker (`hsr-cms`) in a separate repo** (`c:\Anish\Unified CMS`);
**this repo's worker has no `/admin`** (legacy in-repo CMS removed 2026-07-20).

Two scopes: **wallpapers** and **ringtones** (added 2026-07-17). Ringtone audio lives at
`ringtones/<category>/<uuid>.mp3`, cover art at `ringtones/covers/<category>/<uuid>.jpg`.

## Manual rebuild / verify
Custom domains `arul-api` / `arul-cdn.hsrutility.com` are **not attached yet** (NXDOMAIN — they fail
with a DNS error, not an auth error). Use the live origins:
```bash
API=https://arul-api.twilight-smoke-d495.workers.dev
CDN=https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev

curl -X POST $API/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
curl -s $CDN/catalog/version.json                            # content_version + built_at
curl -s "$CDN/catalog/wallpapers/all_1.json?v=<version>"
curl -s "$CDN/catalog/ringtones/all_1.json?v=<version>"      # check BOTH — a rebuild can succeed
                                                             # for one scope and fail for the other
```
A zero-row scope still writes an explicit empty `all_1.json` (`total: 0`), so a 404 here means that
scope failed to build — not that it is empty. Ringtones is legitimately empty today (0 published).

Stale content ≠ cache bug: pages are DYNAMIC; version.json is no-store. Fix by rebuilding, never by cache-purging.

## Initial wallpaper import — port-map Phase 3, COMPLETED 2026-07-14 (historical)
How the original 428 got in; kept for reference and for re-running the shape of it. Bulk additions
since then go through `tools/content-import/` (see its README).
1. Import source = the bucket's own `catalog/catalog.json` manifest (428 assets; all qcStatus=pass
   and sampled media conformed — no re-encode needed; spot-check a few anyway).
2. Existing keys stay as-is: `wallpapers/<category>/<hex>.{jpg|mp4}` (`full_key` is arbitrary text).
3. Map per asset: mediaKey→full_key · mediaType image/video→type static/live · **category→category**
   (first-class column — the browse axis) · subjectName/categoryName→title · delivered dims→width/height ·
   sizeBytes→bytes · scores.rank→sort_order · durationS unreliable (mostly 0) — ffprobe or leave null.
4. ONE Neon transaction: insert all rows + `content_version = content_version + 1`.
5. Rebuild catalog; verify DB = catalog = R2 counts match each other (428 at import time; 514 today)
   and all 6 categories present; CDN URLs 200.
6. ⚠ Objects left without rows are DELETED by the hourly sweep-canonical — intended cleanup; make sure
   everything wanted is in the DB first. The manifest itself sits outside swept prefixes and survives.
   Violators, if any turn up: re-encode from masters — but the masters path recorded here
   (`C:\Anish\content-wallpaper(southindian)`) **no longer exists on disk**; locate them before
   relying on this step. (`tools/content-import/` stages under `c:/Anish/arul-import/` instead.)

## Bulk replace (proven flow in the reference app)
Re-encode locally → PUT to R2 → one txn (delete old rows + insert new + version bump) → rebuild →
verify new URLs 200 / old keys 404 → old objects swept hourly.

## Orphan sweeps (manual)
`POST $API/internal/sweep-canonical` and `/internal/sweep-submissions` with
`Authorization: Bearer $CATALOG_BUILD_SECRET`. Hourly cron runs both automatically.
`sweep-canonical` covers **both** canonical prefixes — `wallpapers/` and `ringtones/` (audio **and**
covers) — keeping an object only while a row references it. It never touches `catalog/` or `user/`.
