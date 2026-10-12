# Win-back push — one push after a payer revokes outside the app

Read before touching `workers/src/lib/winback-push.ts`, `workers/src/cron/winback-push.ts`, the revoke branches of
`routes/payments.ts` or the parks in `cron/autopay-*.ts`. Sending: [push.md](push.md) · the ₹99 it sells:
[cancel-offer.md](cancel-offer.md) §The winback · the webhook: [phonepe-webhook.md](phonepe-webhook.md).

A revoke in the UPI app never opens the app, so it skips the in-app cancel offer, and most trial cancels are these.
This is the Worker's ONE automated push: the ₹99 winback, landing on the ₹99 sheet.

## Only the payer's own revoke queues

- **REVOKED is "cancelled from the user's end"; CANCELLED is the merchant cancel API, which only we call.** A
  CANCELLED live row is recorded `skipped: merchant_cancel`, never sent; EXPIRED, FAILED or no state writes no row.
  Read root `payload.state`; the event name stands in only when a payload omits it. A steady stream of
  `merchant_cancel` rows means payers' own cancels arrive as CANCELLED: revisit the rule, not the copy.
- **`withWinbackRecord` is the ONE home.** It wraps the park's UPDATE in a CTE, so the row change and the win-back
  row commit together: a failed insert cannot lose the push, a redelivery cannot double it. Only a live plan
  qualifies (prior trialing/active/paused): a pending claim's own id dying is a failed setup, and an
  already-cancelled row was cancelled in-app.
- **The insert rides the revoke statement**, so free-text columns carry no CHECK and every bind is `?? null`: a
  surprise value must never fail the revoke. `35_winback_push.sql` lands BEFORE the Worker that writes it.
- Every park passes the raw PhonePe state: webhook, status route, Pass A/B/D (`parkMandate`), legacy reconcile.
  The offer gate records `skipped: in_app_cancel` — that person is inside the cancel offer already.
- **`handleCancel` claims its live and parked ids as `skipped: in_app_cancel` BEFORE it calls PhonePe**: our own
  cancel's webhook can land ahead of the UPDATE and read a live row, and a switch in flight brings the ₹199 back live
  first. Best effort: a failed claim never blocks a cancel.

## The resolver — first on the `* * * * *` trigger

- SQL only, then `.catch`, then `runPushDispatch` in the same chain: the dispatcher drains what it queued this tick,
  and a resolver failure never stops a campaign.
- Gates: `PUSH_ENABLED`, then IST quiet hours 22:00–09:00 (cron time is UTC, India keeps no DST), then the claim
  under `FOR UPDATE OF wp SKIP LOCKED` (the minute trigger has no `cron_runs` slot). `now` is the tick's
  `scheduledTime` bound into the SQL, never `now()`, so tests and `?time=` can pin it.
- **Due = `greatest(revoked + 20 min, current_period_end − 24 h)`.** An accepted winback charges ₹99 on approval
  and starts a fresh month that day (`grantSetup`), so a paid revoker asked early would throw paid days away; a
  trial revoker is asked 20 min after the revoke.
- First match wins: `stale` (due over 24 h ago: no backlog blast after a switch or an outage) · `live_again` (the
  same mandate live again: an in-flight debit settles with no status guard) · `new_setup` (another mandate, or
  `pending`) · `not_eligible` (`winbackOfferEligible`) · `no_phone` (`reachableDevice`, no build gate) ·
  `disabled` · `old_build` · `capped` · `sent`.
- **`disabled` sits after `no_phone` on purpose**: the dark-launch rows ARE the baseline, the same "eligible and
  reachable" group that later gets pushes.

## Month rows — the CMS sees them, the dispatcher sends them

- One `push_campaigns` row per group per IST month, `auto_key = winback:<trial|paid>:YYYY-MM`, on a PLAIN unique
  index: NULLs stay distinct for CMS rows, and `ON CONFLICT (auto_key)` cannot infer a partial one (42P10).
- Born `sent`, so `startDueCampaigns` never claims it. A delivery insert reopens it `sending` and adds to `total`
  (test phones left out, as on any non-internal campaign); the dispatcher drains it back to `sent`. Upsert trial
  before paid, always: the upsert locks the row, and one order keeps overlapping ticks from deadlocking.
- **Every tick reopens a `sent` auto row holding a pending delivery**: an overlapping drain can count zero, then
  flip the row just after an insert committed. Never a `failed` one: its `last_error` restarts the token count.
- **One win-back per phone per IST month across BOTH groups** (`capped`): a trial revoker who came back on ₹99 and
  revoked again already heard the offer (CCPA "nagging").
- `dest = premium` keeps it PRIVATE on the lock screen; `dest_id = winback_99` is what a new build reads to open the
  sheet; `expires_hours = 6`. Deliveries go with the 30-day campaign sweep; resolved `winback_pushes` at 90 days.

## The app

- `/premium?source=push&offer=winback_99` opens the ₹99 sheet once through `_startPaid` — never the Resubscribe
  closure, which fires `resubscribe_tapped` — from the paywall or the Resubscribe page, re-armed in
  `didUpdateWidget` because go_router keeps the State. Its offer events carry `entry: push` (GA4 reports it only
  once `entry` is registered as an event-scoped custom dimension).
- Each arrival first re-runs the open-time reconcile and decides ONCE, on the `/me` it re-reads: a `/me` cached
  before the revoke still reads as a live plan. The push never retries; the app-open sheet may offer ₹99 later,
  and the push's decline only closes, like every door no pay tap opened ([winback-reach.md](winback-reach.md)).
- An older build ignores `offer` and shows ₹199 first, so the resolver sends only to
  `app_build % 1000 >= WINBACK_MIN_BUILD`: the versionCode of the release that ships the landing.

## Copy and switches

- No time and no "keep": the charge starts on approval, a paused row has no premium, and the 09:00 hold can land
  after the period ended. No countdown, no guilt, no "we noticed" (CCPA false urgency, confirm-shaming, nagging).
  Six languages in `lib/winback-push.ts`, terms taken from the app's ARB files; the owner approves every word.
- `WINBACK_PUSH_ENABLED` (`[vars]`, under `PUSH_ENABLED`): `"true"` and nothing else sends. Flipping it is the
  owner's call; until then due rows resolve `disabled`.

## Rehearse

- PGlite: `OPUS55-PHONEPE-HARNESS/suite-r-revoke` — `node build.mjs && node out/run.mjs`. It binds :5433, so never
  beside `pgserver.mjs`; its fake answers a merchant cancel CANCELLED, as UAT does.
- HTTP (verify-payments Mode B): PGlite serves ONE connection, so a seeding script must not hold one across a call
  to the Worker or both wait ~2 min. `wrangler dev --test-scheduled --var PUSH_ENABLED:true --var
  WINBACK_PUSH_ENABLED:true --var POSTHOG_HOST:http://127.0.0.1:9`, then
  `/cdn-cgi/handler/scheduled?cron=*+*+*+*+*&time=<12:00 IST ms>`. A dummy token answers `INVALID_ARGUMENT`: the
  message reached FCM.
- The Neon debug branch is a prod copy with real tokens: skip every queued row that is not yours before
  `cron-rehearse.mjs push --allow-push`.

## Measure

Read-only through `tools/prod-query.mjs`; compare the `disabled` weeks with the `sent`/`old_build`/`capped` weeks.
"Came back" is the row now naming a newer live mandate — the table keeps no per-setup timestamp.

```sql
SELECT date_trunc('week', wp.created_at AT TIME ZONE 'Asia/Kolkata')::date AS week,
       wp.prior_status = 'trialing' AS trial, wp.state, wp.skip_reason, count(*) AS rows,
       count(*) FILTER (WHERE s.merchant_subscription_id <> wp.mandate_id
                          AND s.status IN ('trialing', 'active')) AS came_back,
       count(*) FILTER (WHERE s.merchant_subscription_id <> wp.mandate_id
                          AND s.status IN ('trialing', 'active') AND s.price_paise = 9900) AS came_back_99
FROM winback_pushes wp LEFT JOIN subscriptions s ON s.user_id = wp.user_id
GROUP BY 1, 2, 3, 4 ORDER BY 1 DESC, 2, 3, 4;
```

## Contracts

- [ ] A REVOKED live mandate queues one row, whichever path saw it first; a redelivery adds nothing
- [ ] CANCELLED, EXPIRED, FAILED, a pending claim's own id, an already-cancelled row: never a queued row
- [ ] An in-app cancel never gets the push — mid-switch, and when its own webhook lands first
- [ ] Trial: 20 min after the revoke; paid: a day before the period ends; nothing 22:00–09:00 IST
- [ ] Came back, live again, ineligible, no phone, old build, switch off, stale, pushed this month: no push, and
  the reason is on the row
- [ ] The tap opens the ₹99 sheet once — killed, backgrounded, already on /premium; the lock screen shows nothing
- [ ] The month row's counters and language rows add up like any campaign's; a tap records an open
