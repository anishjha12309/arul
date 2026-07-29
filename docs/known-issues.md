# Known Issues

Open defects only. Close a line or delete it — don't let it rot.

## Open

- **Existing media objects carry no `Cache-Control`.** Both custom domains went live 2026-07-29 and
  caching is confirmed working (`MISS`→`HIT`) for catalog JSON via the Cache Rule and for media via
  Cloudflare's default extension list. But objects imported before today were uploaded with only a
  `content-type` — verified against the raw r2.dev origin, which bypasses edge caching. Without an
  origin header the edge uses Cloudflare's shorter default TTL, so media ages out sooner and each
  miss costs an R2 **Class B operation** — the one part of R2 that is not free, on the highest-volume
  thing this app serves (CLAUDE.md §2). `tools/content-import/import.mjs` now stamps
  `public, max-age=31536000, immutable` on new uploads (keys are content UUIDs and never change), so
  this only affects the ~614 already in the bucket. Fix by either a metadata rewrite (S3 CopyObject
  with `MetadataDirective=REPLACE` — server-side, no egress) or a media Cache Rule using *"Ignore
  cache-control and use this TTL"*, which covers old and new objects at once with no code.

## Measurement trap — cost an hour on 2026-07-29, do not repeat

**`curl -I` (HEAD) does not populate Cloudflare's cache, and reports `DYNAMIC` for assets that cache
perfectly well over GET.** A whole afternoon was spent "fixing" a Cache Rule that was correct from
the start, because every measurement used HEAD. A warm host (Pakiza, with real user traffic) returns
`HIT` to a HEAD request, while a brand-new host with no traffic returns `DYNAMIC` — which reads
exactly like a broken rule. Always verify with GET:

```
curl -s -o /dev/null -D - "https://arul-cdn.hsrutility.com/catalog/version.json" | grep -i cf-cache-status
```

First GET `MISS`, second `HIT`. The `?cb=<random>` cache-buster habit makes it worse: it creates a
distinct cache key per request, so nothing can ever be a hit.

## Cloudflare caching — how it actually behaves (learned in the reference app)

`.json` is **not** in Cloudflare's default cacheable-extension list, so on a zone host every catalog
file would be `DYNAMIC` unless a Cache Rule matching the host + `/catalog/` prefix marks it
*Eligible for cache* with Edge TTL **"Use cache-control header if present, bypass cache if not"**.
With that setting the **origin header alone decides** — anything written `no-store` is bypassed
automatically, so the rule needs no per-path exclusions. A leftover `version.json` exclusion is
exactly what kept Pakiza's pointer at `DYNAMIC`/~240 ms while its siblings served `HIT`/~40 ms.
The zone also rewrites `max-age` downstream (Browser Cache TTL 4 h) — the edge still honours the
origin TTL, and the app's `package:http` implements no HTTP cache, so freshness is unaffected.
Don't read a header off the CDN and assume it is what the Worker wrote.

## Ported from the reference app 2026-07-29

Pakiza's 2026-07-27 audit-fix session (its worker `7ba9941a`), ported wholesale — see that repo's
`docs/known-issues.md` for the full write-ups:

- **Cold-DB cron hardening** — `connect_timeout: 5`, retry-once on a fresh connection in both
  crons, non-throwing `sql.end()` teardown. A cold Hyperdrive socket killed Pakiza's hourly cron
  for 3 h unnoticed.
- **Cron split** — hourly (catalog + on-change canonical sweep + autopay) / daily 21:30 UTC
  (unconditional canonical + submission sweeps). Arul had never received the 2026-07-24 split.
- **A second `/payments/initiate` can no longer orphan a live mandate** (serialized on the user
  row, in-flight setups refused, superseded mandates revoked).
- **A lapsed subscription no longer swallows a ₹199 payment**; the webhook no longer 500s on a
  successful signup.
- **Stuck-`PENDING` debits converge** — Pass C reconciles via `getOrderStatus` once >2 h overdue.
- **`version.json` is edge-cacheable** — `public, max-age=30, stale-while-revalidate=300` instead
  of `no-store`; monotonic guard relaxed to allow same-version rewrites.
- **Catalog ordering is deterministic** — scope queries end in `id ASC`.
- **`/media/signed-url` does one DB round-trip**, not two; `/submissions/` key infix enforced.
- **App:** feeds self-recover (5 s→2 min ladder) · lapsed 403 routes to the paywall (no
  Crashlytics non-fatal) · cold start makes one `GET /me` (5 s replay window) · re-applying a
  cached wallpaper is entitlement-gated (still allowed offline).

## Billing verified 2026-07-29 (UAT + on-device) — known-good baseline

The whole Autopay lifecycle was exercised against PhonePe **UAT** on a real device (Nothing Phone,
PhonePe Simulator) plus a local stub for the terminal states UAT refuses to settle. Worker
`cc00fb34`. Do not re-derive these; re-run `.claude/skills/verify-payments/` if the billing code
changes.

| Step | Proven by | Result |
| --- | --- | --- |
| ₹2 PENNY_DROP trial mandate | device + PhonePe Simulator | authorized; PhonePe `COMPLETED` |
| Repeat subscriber → ₹199 | fresh initiate, trial consumed | `trialEligible:false`, `amountPaise:19900` |
| Double-tap checkout | two concurrent initiates | both 409 `setup_in_progress`, no 2nd mandate |
| 24 h notifier | `next_debit_at` = now+20 h | Pass A notified, **Pass B refused to debit early** |
| ₹199 debit after trial | `next_debit_at` backdated | real UAT `redeem`; UAT holds `PENDING` |
| Debit settles | `subscription.redemption.order.completed` webhook | `active`, period +1 month, `notified_at` cleared |
| Debit fails / dunning | local stub `FAILED` | retries 1–4 alive, **expired at 5**, then ignored |
| Cancellation | `POST /payments/cancel` | `cancelled`, **period stays live**, `next_debit_at` NULL |
| Rebuy after cancel | initiate on cancelled row | `19900` — no ₹2 trial |
| Delete → re-login | `DELETE /me` then real Google sign-in | tombstone written; new row pre-seeded `expired` with the OLD `trial_end` → ₹199 |

Notes worth keeping:
- **Time is the only thing simulated.** Notify/redeem/renewal are driven by `next_debit_at`, so
  backdating it is indistinguishable from waiting. No need to wait out a real trial day.
- **`phonepe_subscription_id` can stay NULL** when the webhook is lost and only the status-reconcile
  runs. Harmless: the cron addresses PhonePe by *our* `merchant_subscription_id`.
- **A lost SDK callback does not lose the payment.** The device run ended with PhonePe's webview
  stuck on "confirming payment" (their UAT bundle's own event POSTs are CORS-blocked); the mandate
  was `COMPLETED` at PhonePe and `POST /payments/status` reconciled the row to `trialing`. That
  recovery path is load-bearing — do not remove it.
- **Local dev cannot receive the real S2S webhook** (`127.0.0.1` is unreachable from PhonePe). Drive
  the handler with `tools/prod-webhook.mjs` instead; only the final network hop is unproven locally.
- **Two `wrangler dev` instances can both hold 8787** and the stale one silently serves the app with
  the old config — that produced a phantom `502 phonepe_error`. Check
  `netstat -ano | grep :8787` before blaming code. Also delete KV `phonepe:oauth` after switching
  between the stub and real UAT, or a stub-issued token is replayed against the real host.

## Still unverified — needs a human

- **Production webhook delivery for Arul** — the only billing hop UAT + local cannot cover
  (PhonePe → `api.hsrutility.com` → `DKS_` dispatcher → arul-api). Same path already works for
  Pakiza in production.
- **The daily 21:30 UTC sweep** observed live on this worker.
- **One cron run on a genuinely cold connection ending `outcome: ok`** — same residual as the
  reference app; check `npx wrangler tail --format json` over a `:00` after several idle hours.
  (The hourly cron was observed succeeding at 11:00:01 on 2026-07-29, minutes after deploy, but on
  a warm connection.)
- **Ringtones have no content** — `ringtones` is empty in prod, so that tab renders empty. CMS job,
  not a code defect.
