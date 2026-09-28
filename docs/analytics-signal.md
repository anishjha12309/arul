# Analytics signal — more per event, never more events

**The PostHog event count is fixed (owner).** Every new signal rides an event that already fires, a
`register()` super property, a person property on the `identify` sign-in sends, or a Neon column PostHog
reads through its warehouse. Events and the allow-list: [analytics-events.md](analytics-events.md).

## On the events

- `JourneyStamps` (`lib/core/analytics/journey_stamps.dart`) holds the install-lifetime counters, clocks
  and phone facts. Launch props and the PERSISTED referrer attribution are primed before `setup()`, so
  every event of a later launch carries the channel. Counters read null, never 0, in a process that
  never ran `start()`.
- Sign-in events carry the history BEFORE the attempt (`prev_outcome`, `left_since_prev`, `cancels_n`…),
  frozen at `login_attempt`. Every outcome goes through `noteSignInOutcome` — the stall guard's too —
  or the next attempt reports a history that never happened.
- **Native probes start only once Google's surface is up** (`login_surface_shown`), or 3 s after the
  first frame. Platform-channel calls are served in order on the main thread, so one queued ahead of the
  credential request delays Google's sheet. So `login_attempt` never carries `gms_version`, `upi_apps`
  or `net_*`; the outcomes do.
- `POST /auth/login` returns an `analytics` object spread verbatim onto `login_success` (`new_user`,
  `sub_status`, `trial_used`, `account_age_d`, `internal`, `paid_before`, `referred`): a new key is a
  Worker deploy, not a release. Analytics only — the gate stays `premiumPredicate`. Divide login→trial
  by `trial_used = false`: a spent trial can only buy at ₹199.
- Every sign-in event also carries how the app RENDERED up to it (`slow_frames`, `worst_frame_ms`,
  `wall_clip`); the device probe adds `thermal`, `launch_source`, `ms_before_main` and `data_saver`,
  and the stable facts persist so a relaunch's first attempt carries them. `data_saver` is sent only
  when the facts channel answered: Data Saver's own fallback `false` would otherwise read as a fact.
- `trial_started` carries the path to it (`checkout_n`, `paywall_n`, `paywall_source`, `gate_*`,
  `cards_n`, `previews_n`, `s_on_paywall`, `s_tap_to_trial`), all persisted, so the late catch-up copy
  carries them too.
- Channel, tier, `gms_version`, `upi_apps` and `is_internal` also go to the PERSON on `identify`, so the
  server events (`subscription_*`, no device context) break down by them.
- **GA4 never sees the diagnostics:** `kPostHogOnlyProperties` is dropped from GA4 events AND user
  properties — GA4 caps an event at 25 parameters and a project at 25 user-property names. A new
  diagnostic key goes IN the set; a key GA4 already reports on (`upi_apps`, `paywall_source`, `low_ram`,
  `install_*`) never does, or that GA4 report goes blank.

## In Neon, read through the warehouse

- Source `neon` (role `posthog_reader`, `db/schema/26_*`/`27_*`) syncs `postgres.neon.subscriptions`
  (incremental on `updated_at`, which the `subscriptions_set_updated_at` trigger bumps on every write),
  `postgres.neon.paywall_views` (incremental on `last_at`, key `user_id, source`) and
  `postgres.neon.posthog_internal_users`. Never `users`: email and name stay out of PostHog. The password
  lives only in the source; lost → `ALTER ROLE posthog_reader PASSWORD …` and re-enter it.
- A view cannot sync incrementally (PostHog needs a primary key), so only a tiny view is a view.
- `subscriptions.checkout_context` = `JourneyStamps.checkoutContext()` sent with `/payments/initiate`;
  `paywall_views` = one `POST /me/paywall-view` per paywall screen, `views` counting, `context` latest —
  the only record of people who look and never tap. Both go through `lib/analytics-context.ts` (flat
  scalars, ≤60 keys, 100 chars): junk is dropped, never a reason to refuse a checkout.
- **Bind JSON as `${JSON.stringify(x)}::text::jsonb`, never `::jsonb`.** postgres.js JSON-encodes a
  parameter it sees typed jsonb, so a pre-stringified value lands as a jsonb STRING and every `->>`
  reads NULL. PGlite does not reproduce it; only the real driver (`jsonb_typeof`) proves the shape.
- The Worker stamps Cloudflare's view of the connection (`isp`, `rtt_ms`, `colo`, `region_code`, `asn`,
  `http`, `tls` — never city) onto the login analytics, paywall views, taps and checkout events
  (`lib/request-signal.ts`). The login keys ride AFTER the account facts: build 87 keeps only the
  first 12 keys it is sent.
- A paywall view's END (`last_exit` = `cta`/`back`/`left_app`, `last_dwell_s`) is a second POST to
  the same route; NULL `last_exit` = the app left from the paywall and never came back to close it.
  Checkout failures append to `checkout_events` (`POST /me/checkout-event`), never the subscriptions
  row: its trigger bumps `updated_at`, which also bounds the in-flight checkout window.
- Join `toString(s.user_id) = distinct_id`. A LEFT JOIN miss is NULL on the warehouse side but `''` on
  an events-side column — test `IS NULL` / `!= ''` accordingly, or every sign-in counts as a checkout.
- The subscriptions row appears at the first CTA tap and every later tap OVERWRITES it: the latest
  attempt, not history. `pending` = tapped, never approved; `expired` on a new account = the tombstone
  pre-seed. The tap time is the base36 ms in `merchant_order_id`'s 4th `_` field.
- Test accounts out: `distinct_id NOT IN (SELECT toString(id) FROM postgres.neon.posthog_internal_users)`.
