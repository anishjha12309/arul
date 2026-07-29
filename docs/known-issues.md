# Known Issues

Open defects, deliberate gaps and unverified claims only. Close a line or delete it — don't let it rot.
Verified-and-closed billing behaviour lives in [billing-verified.md](billing-verified.md).

## Open

- **Ringtones are PARKED for v1, not merely empty.** The `ringtones` table is empty in prod, so the
  tab only ever rendered "coming soon" — shipping a dead tab is worse than shipping no tab. So the
  ENTRY POINT is commented out: `lib/app/router.dart` routes `/browse` as a plain top-level route
  instead of the `StatefulShellRoute` (killing the dock and the ringtones branch), and
  `AndroidManifest.xml` comments out `WRITE_SETTINGS` — a special-access permission Play reviews, with
  no feature behind it. Grep `RINGTONES-PARKED` for every line.
  **Nothing is deleted and nothing is a defect.** `features/ringtones/**`, `app/shell/app_shell.dart`,
  the `ringtone*` ARB keys, the worker's `ringtones` catalog scope and the `ringtones/` sweep prefix
  are all intact and still type-checked; Dart just tree-shakes them out of the build.
  **To un-park:** publish ringtone audio to the bucket FIRST (audio in R2 + rows in Neon + a rebuild —
  otherwise the tab is dead again), then in `router.dart` uncomment the `StatefulShellRoute` block,
  delete the temporary `/browse` route, restore the `app_shell.dart` + `ringtones_screen.dart`
  imports; uncomment `WRITE_SETTINGS`; drop the parked header on `app_shell.dart`. Full procedure and
  the dock reference screenshots: [reference/ringtones-parked/README.md](reference/ringtones-parked/README.md).

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
