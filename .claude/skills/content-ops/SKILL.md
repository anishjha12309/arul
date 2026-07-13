---
name: content-ops
description: Arul content/catalog operations — publish, rebuild, verify, bulk import/replace wallpapers, orphan sweeps. Use when content isn't showing, catalog is stale, or wallpapers must be added/replaced in bulk.
---

# Content Ops

**Primary authoring = CMS** `https://arul-api.hsrutility.com/admin` — row write + version bump +
rebuild + purge atomically. Prefer it; go direct only for bulk jobs. Wallpapers only (no ringtones).

## Manual rebuild / verify
```bash
curl -X POST https://arul-api.hsrutility.com/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
curl -s https://arul-cdn.hsrutility.com/catalog/version.json          # content_version + built_at
curl -s "https://arul-cdn.hsrutility.com/catalog/wallpapers/all_1.json?v=<version>"
```
Stale content ≠ cache bug: pages are DYNAMIC; version.json is no-store. Fix by rebuilding, never by cache-purging.

## Initial import (port-map Phase 3 — bucket is pre-populated, DB is empty)
1. Import source = the bucket's own `catalog/catalog.json` manifest (428 assets; verified 2026-07-14,
   all qcStatus=pass and sampled media conforms — no re-encode expected; spot-check a few anyway).
2. Existing keys stay as-is: `wallpapers/<category>/<hex>.{jpg|mp4}` (`full_key` is arbitrary text).
3. Map per asset: mediaKey→full_key · mediaType image/video→type static/live · **category→category**
   (first-class column — the browse axis) · subjectName/categoryName→title · delivered dims→width/height ·
   sizeBytes→bytes · scores.rank→sort_order · durationS unreliable (mostly 0) — ffprobe or leave null.
4. ONE Neon transaction: insert all rows + `content_version = content_version + 1`.
5. Rebuild catalog; verify counts DB = catalog = R2 (428) and all 6 categories present; CDN URLs 200.
6. ⚠ Objects left without rows are DELETED by the hourly sweep-canonical — intended cleanup; make sure
   everything wanted is in the DB first. The manifest itself sits outside swept prefixes and survives.
   Violators, if any turn up: re-encode from masters (`C:\Anish\content-wallpaper(southindian)`).

## Bulk replace (proven flow in the reference app)
Re-encode locally → PUT to R2 → one txn (delete old rows + insert new + version bump) → rebuild →
verify new URLs 200 / old keys 404 → old objects swept hourly.

## Orphan sweeps (manual)
`POST /internal/sweep-canonical` and `/internal/sweep-submissions` with `Authorization: Bearer $CATALOG_BUILD_SECRET`. Hourly cron runs both automatically.
