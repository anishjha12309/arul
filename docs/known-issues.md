# Known Issues

Open defects and unverified claims only. Close a line or delete it — don't let it rot.
Verified-and-closed billing behaviour lives in [billing-verified.md](billing-verified.md).

## Open

- **`FLAG_SECURE` is not set.** Absent from both `android/` and `lib/` — screenshots and screen
  recording of the app are unrestricted, and the whole catalogue is premium-gated content. Pakiza
  ships it app-wide. **Add before the Play listing goes public**, not after.

- **Ringtones have no content.** The `ringtones` table is empty in prod, so `catalog/ringtones/all_1.json`
  is a valid `total: 0` page and the tab renders its empty state. A content job for the CMS, not a code
  defect — do not "fix" it in the app.

- **Media imported before 2026-07-29 carries no origin `Cache-Control`.** `tools/content-import/import.mjs`
  now stamps `public, max-age=31536000, immutable` on upload, but the ~614 objects already in the
  bucket have only a `content-type`. The media Cache Rule ("ignore cache-control, use TTL") covers
  them at the edge, so this is latent rather than live: it only bites if that rule is ever removed or
  narrowed. Fix properly with an S3 CopyObject metadata rewrite (`MetadataDirective=REPLACE` —
  server-side, no egress) if you want the objects self-describing.

## Still unverified — needs a human

- **Production webhook delivery for Arul** — PhonePe → `api.hsrutility.com` → `DKS_` dispatcher →
  arul-api. The only billing hop UAT and local cannot cover; the same path already works in production
  for Pakiza.
- **The daily 21:30 UTC sweep observed live** on this worker.
- **One cron run on a genuinely cold connection ending `outcome: ok`.** The hourly cron was seen
  succeeding at 11:00:01 on 2026-07-29, but minutes after a deploy — a warm connection. Watch
  `npx wrangler tail --format json` over a `:00` after several idle hours. Same residual as Pakiza.

## Traps already paid for

- **Measuring the CDN with `curl -I`.** HEAD does not populate Cloudflare's cache and reports
  `DYNAMIC` for assets that cache perfectly well over GET — an afternoon on 2026-07-29 went into
  "fixing" a Cache Rule that was correct from the start. The method that works, and the two live Cache
  Rules, are in [caching.md](caching.md).
- **A `version.json` exclusion on the catalog Cache Rule.** Looks protective, kept Pakiza's pointer
  uncached for days. [caching.md](caching.md).
- **`PHONEPE_ENV` set through a shell pipe.** A trailing newline routes production credentials to the
  sandbox host and the 401 is indistinguishable from bad credentials. [phonepe.md](phonepe.md).
