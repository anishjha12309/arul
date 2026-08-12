# CDN Caching — rules, headers, and the two traps

Read this before changing a Cache Rule, a `Cache-Control` header, or before concluding
"the CDN isn't caching". Every fact here was paid for once already.

Media egress is the whole cost model (CLAUDE.md §2), so an edge miss is not just latency — each one
costs an R2 **Class B operation**, the one part of R2 that is not free, on the highest-volume thing
this app serves.

## The two zone Cache Rules on `arul-cdn.hsrutility.com`

`.json` is **not** in Cloudflare's default cacheable-extension list, and neither rule applies to
`r2.dev` at all — a bucket must sit behind a custom domain to be cacheable.

| Rule | Match | Edge TTL |
| --- | --- | --- |
| Catalog JSON | `starts_with(http.request.uri.path, "/catalog/")` | **Use cache-control header if present, bypass if not** |
| Media | everything NOT under `/catalog/` | **Ignore cache-control, use this TTL** = `31536000` |

Both are verified caching (`MISS` → `HIT`).

**The catalog rule must have NO per-path exclusions.** With "use cache-control header if present",
the origin header alone decides — anything the Worker marks `no-store` is bypassed automatically. A
`version.json` exclusion looks protective and is the exact trap that kept Pakiza's pointer at
`DYNAMIC`/~240 ms while its siblings served `HIT`/~40 ms, for days. Do not add one.

The media rule ignores origin headers on purpose: it covers old and new objects identically, so no
metadata rewrite is needed for anything already in the bucket.

## `Cache-Control` written by this repo

- `catalog/version.json` — `public, max-age=30, stale-while-revalidate=300`. Short TTL keeps the
  pointer fresh; SWR stops a burst of cold clients stampeding the Worker. **Not `no-store`** — that
  made it the one uncacheable request on every cold start.
- `catalog/<scope>/all_{page}.json` — `public, max-age=86400`, busted by `?v=<content_version>`.
  A page body is immutable for its `?v` key, so a long TTL is safe. **Never let these fall back to
  `putPublicJson`'s `max-age=60` default**: at 60 s effectively every real fetch was `REVALIDATED`
  against R2 origin — 0.5–1 s per page with multi-second outliers — and the ringtone tab's serial
  8-page drain stacked that into a ~5 s first open, and the wallpaper cold start (no disk snapshot
  yet) idled just as long behind 32 pages (fixed 2026-08-11: 200 rows/page for both scopes plus a
  parallel drain in the app).
- Media uploaded by `tools/content-import/import.mjs` — `public, max-age=31536000, immutable`
  (keys are content UUIDs and never change). The ~614 objects imported before that stamp carry only
  a `content-type` and rely on the media Cache Rule instead.

The zone rewrites `max-age` downstream (Browser Cache TTL 4 h), so a header read off the CDN is not
what the Worker wrote. The edge still honours the origin TTL, and the app's `package:http`
implements no HTTP cache, so freshness is unaffected.

## Measurement trap — cost an hour on 2026-07-29

**`curl -I` (HEAD) does not populate Cloudflare's cache, and reports `DYNAMIC` for assets that cache
perfectly well over GET.** An afternoon went into "fixing" a Cache Rule that was correct from the
start, because every measurement used HEAD. A warm host with real traffic answers HEAD with `HIT`; a
brand-new host with none answers `DYNAMIC` — which reads exactly like a broken rule.

Measure with GET:

```bash
curl -s -o /dev/null -D - "https://arul-cdn.hsrutility.com/catalog/version.json" | grep -i cf-cache-status
```

First GET `MISS`, second `HIT`. Drop the `?cb=<random>` cache-buster habit while measuring: a unique
query string is a unique cache key, so nothing can ever be a hit. (Use it only when reading
`Last-Modified` to check cron liveness — see [cron.md](cron.md).)

## Staleness is never a purge problem

Catalog pages go stale because `content_version` did not move or a rebuild failed. Rebuild
(`POST /internal/build-catalog`); never reach for a cache purge.

**A rebuild that does not move `content_version` no longer propagates** (hit 2026-08-11): with
`max-age=86400` the edge keeps serving the old page bodies under the same `?v=` key for up to a day
— and because a rebuild deletes pages it no longer writes, a colo without the old copies 404s the
tail and a fresh drain silently truncates. Under the old `max-age=60` a bare rebuild self-healed in
a minute, which is what the rule above used to lean on. So: any rebuild that changes page
*layout or contents* (page-size change, orphan sweep, schema tweak) must ride a version bump —
CMS publishes bump automatically; for an operational rebuild, bump first:

```bash
node tools/prod-sql.mjs --write "UPDATE app_config SET content_version = content_version + 1 WHERE id = 1"
```

## Negative caching: a 404 outlives the upload that fixes it (accepted tradeoff)

The media Cache Rule caches 404s briefly too, so probing a key on the CDN **before** uploading it
(observed 2026-08-01 with backfilled `thumbs/`) leaves that edge serving 404 for a few minutes after
the object lands. Accepted: it self-heals, and every `thumbs/` consumer falls back (the app to the
native first-frame still, the CMS panel to the static original). Check existence against the
S3 API or with a `?v=` cache-buster, not the bare CDN URL.
