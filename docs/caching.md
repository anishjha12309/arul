# CDN caching — rules, headers and the measurement traps

Read before changing a Cache Rule or a `Cache-Control` header, or before concluding "the CDN isn't
caching". Media egress is the whole cost model (CLAUDE.md §2): every edge miss is an R2 **Class B
operation** — the billed part of serving reads — on the highest-volume thing this app serves.

## The two zone Cache Rules on `arul-cdn.hsrutility.com`

`.json` is **not** in Cloudflare's default cacheable-extension list, and neither rule applies to
`r2.dev` at all — caching, WAF and access controls need the bucket behind a custom domain.

| Rule | Match | Edge TTL |
| --- | --- | --- |
| Catalog JSON | `starts_with(http.request.uri.path, "/catalog/")` | **Use cache-control header if present, bypass if not** |
| Media | everything NOT under `/catalog/` | **Ignore cache-control, use this TTL** = `31536000` |

**The catalog rule must have NO per-path exclusions.** With "use cache-control header if present" the
origin header alone decides, so anything the Worker marks `no-store` bypasses by itself. A
`version.json` exclusion looks protective and is the exact trap that once held a pointer at `DYNAMIC`
and hundreds of milliseconds while its siblings served `HIT` in tens.

The media rule ignores origin headers on purpose: old and new objects cache identically with no
metadata rewrite. It also caches 404s for its full TTL (below).

## `Cache-Control` written by this repo

- `catalog/version.json` — `public, max-age=30, stale-while-revalidate=300`. The short TTL keeps the
  pointer fresh; SWR stops a burst of cold clients stampeding the Worker. **Never `no-store`** — that
  made it the one uncacheable request on every cold start. `max-age=0, s-maxage=30` was tried and the
  edge ignored the `s-maxage`.
- `catalog/<scope>/all_<page>.json` — `public, max-age=86400`, busted by `?v=<content_version>`; a page
  body is immutable for its `?v`. **Never let these fall back to `putPublicJson`'s `max-age=60`
  default**: at 60 s nearly every fetch was `REVALIDATED` against R2, and the ringtone tab's page drain
  stacked that into a multi-second first open.
- Media uploaded by `tools/content-import/import.mjs` — `public, max-age=31536000, immutable` (keys are
  content UUIDs).

**The zone rewrites `max-age` downstream (Browser Cache TTL 4 h), so a header read off the CDN is not
always what the Worker wrote.** It acts as a floor: `version.json`'s `max-age=30` comes back `14400`
while the pages' `86400` is untouched. The edge still honours the origin TTL, and the app's
`package:http` implements no HTTP cache, so freshness is unaffected.

## Latent: CMS and user uploads carry no origin `Cache-Control`

The CMS presign — like this repo's user-upload presign — signs `Content-Type` alone, so those objects
carry no cache header. **You cannot see the difference from the CDN**: the media rule rewrites the TTL,
so both answer identically. Harmless while that rule stands. If it ever goes, fix BOTH halves or it
recurs: rewrite existing objects' metadata with an S3 CopyObject (`MetadataDirective=REPLACE`), and add
the header to every presign.

## Measure with GET, never `curl -I`

**HEAD does not populate Cloudflare's cache and reports `DYNAMIC` even on this host's warmest keys** —
ones a GET serves as `HIT` at six-figure `Age` — which reads exactly like a broken rule. An afternoon
went into "fixing" a correct rule that way.

```bash
curl -s -o /dev/null -D - "https://arul-cdn.hsrutility.com/catalog/version.json" | grep -i cf-cache-status
```

First GET `MISS`, second `HIT`. **No `?cb=<random>` while measuring**: a unique query string is a unique
cache key, so nothing can ever hit. (It is right only for reading `Last-Modified` — [cron.md](cron.md).)

## Staleness is never a purge problem

Pages go stale because `content_version` did not move or a rebuild failed. Rebuild
(`POST /internal/build-catalog`); this Worker has no purge path at all, and neither does the CMS.

**A rebuild that does not move `content_version` does not propagate.** With `max-age=86400` the edge
keeps the old bodies under the same `?v=` for up to a day, and because a rebuild deletes pages it no
longer writes, a colo without the old copies 404s the tail and a fresh drain silently truncates. So
**any rebuild that changes page layout or contents must ride a version bump.** CMS publishes bump
automatically; for an operational rebuild, bump first — `UPDATE app_config SET content_version =
content_version + 1 WHERE id = 1` through `workers/tools/prod-sql.mjs --write`, with the approval a
prod write requires (`.claude/skills/neon-migration/`).

## A 404 outlives the upload that fixes it (accepted)

The media rule caches 404s for its long TTL, far past Cloudflare's default, so probing a key on the CDN
**before** uploading it leaves that edge serving 404 long after the object lands. Accepted, because
every `thumbs/` consumer falls back (the app to the native first frame, the CMS to a glyph tile).
**Check existence against the S3 API or with a `?v=` buster — never the bare CDN URL.**
