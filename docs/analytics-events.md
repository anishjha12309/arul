# Analytics Events

**Never call SDKs from widgets — always `AnalyticsService`**, which fans out to three sinks. Consoles
and how to read the data: [analytics-ops.md](analytics-ops.md). Ads traps:
[google-ads.md](google-ads.md).

- **PostHog** — every install, and **only the journey**: `Application Installed` → `login_success` →
  `trial_started` → `wallpaper_applied` / `wallpaper_shared` → `ringtone_set`, plus the two sign-in
  diagnostics below. Two gates: `AnalyticsCohort` (is this install in the panel?) and
  `AllowlistedAnalyticsService` (is this event on the list?). SDK lifecycle autocapture is **off**, so
  the install event is emitted by hand in `main.dart` — the one PostHog event that never passes
  through `AnalyticsService`.
- **GA4** (`firebase_analytics`) — **every event at 100%, from every install**, under its raw name,
  plus ★ events emitting GA4 *standard* `login`/`begin_checkout`. **The complete record.**
- **Meta App Events** — ONLY ★ events; installs/launches are auto-logged natively.

★ = `login_success` (GA4 `login`, Meta CompleteRegistration) · `checkout_started` (GA4
`begin_checkout`, Meta InitiateCheckout) · `trial_started` (Meta StartTrial) · `subscription_active`
(nothing to GA4 or Meta).

## ONE conversion action, ONE data source — the rule that must not be re-opened

**No paid conversion reaches any ad platform** (owner's call). GA4 `purchase` and Meta `Subscribe`
are gone from BOTH sides — client mappings, the Worker's GA4-MP and Meta-CAPI reporters, the
`app_instance_id`/`meta_anon_id` uploads, and the `GA4_*`/`META_*` secrets.

**Why it must not come back:** `purchase` had TWO source types — the app SDK for the app-open setup,
and the server (GA4 Measurement Protocol; Meta CAPI `system_generated`, which Meta files as a WEBSITE
event) for the app-closed settle. The two reconcile on different schedules, so one conversion action
with two sources desynchronises attribution: GA4's raw counts stayed correct while the Ads CAMPAIGN
column ran about a day behind and undercounted. **`trial_started`/StartTrial is the ONLY event
campaigns bid on** — app SDK, in-session, one source. **Accepted cost: no revenue or ROAS signal on
either platform. Revenue truth is Neon**, and now the only revenue record.

`trial_started` carries `plan`, `order_id` and `value`. It fires from the purchase poll — or, for a
trial granted APP-CLOSED (webhook resurrect, process killed behind the UPI app, poll budget out),
late from `TrialConversionCatchUp` on the next `GET /me` showing `trialing` for an order this install
never reported (`late: true`, once per order). The catch-up marks BEFORE invalidating entitlement,
and installs predating it grandfather the trial they find, so an update cannot double-count. **Same
app SDK, same single source — never a server copy.**

`subscription_active` reaches **PostHog only** (server, first trial→paid settle) — product analytics
is not an attribution source, and renewals reach nothing. `subscription_cancel` is server-only too:
one event per mandate from every channel that ends a LIVE row, carrying `reason`, `prior_status` and
`during_trial`. Restore-to-cancelled writes after a failed re-setup are NOT cancels.

## The sign-in diagnostics

`login_cancelled` and `login_failed` are on the PostHog allow-list as a **diagnostic exception** to
the journey-only rule; taking them back off is the owner's call. Both carry `gis_code`,
`ms_since_authenticate` and `surface`.

**The two events spell the Credential Manager message differently: `login_cancelled` carries
`description`, `login_failed` carries `error`.** A query that splits "on `description`" returns
nothing for `login_failed`. Why the split matters at all — the mixed-bucket problem — is in
[auth.md](auth.md).

The sign-in SURFACE split is GA4-only, deliberately not on the PostHog list:
`login_attempt{provider, surface, auto}` once per attempt, carrying the FIRST surface tried, and
`sheet_unavailable{gis_code, description, ms_since_authenticate}` when the sheet could not RUN and
the button took over. A sheet that drew nothing emits nothing — nothing failed. Free-text values stay
≤100 chars, because GA4 silently drops longer parameter values.

## The rest of the catalogue

`checkout_started` fires at the TAP, before `/payments/initiate`, so an initiate failure still reads
as an abandoned checkout. Its `method` (`upi_app`|`phonepe_sdk`) and `target_app` are what make
"which UPI app expires the mandate" answerable — the question the paid funnel is actually lost on.
It is a bare string literal, not an `ArulEvents` constant.

`payment_failed` is GA4-only (a failure is a diagnostic; an ad optimiser fed one trains on the wrong
outcome) and covers EVERY terminal exit of the purchase notifier through a single `_fail()`, so a new
error path cannot silently skip it. **`reason` is a short stable code, NEVER the user-facing copy**,
which is prose and would fragment the metric.

The event LIST is the `track()` call sites — no table here to drift. The ★ NAMES are constants in
`analytics_events.dart` and the PostHog allow-list is an exact set, both pinned by tests, because
every sink matches the literal and a typo would drop silently.

## PostHog is the journey view — and the gates that keep it that way

Two different reasons trim this stream, and confusing them leads to the wrong fix. **Cost sets the
COHORT** — PostHog bills per event on a 1M/month free tier, and there is no cost to control until the
install base produces one. **Readability sets the LIST** — the journey list is far inside the tier;
it is short because install → login → trial → apply/share → ringtone set answers the only questions
PostHog is asked here. Re-adding an event is a decision, not a cleanup.

- **`AnalyticsCohort` gates `Posthog().setup()` itself**, so a non-panel install does zero PostHog
  init, network or battery work. **Widening is safe by construction; narrowing is not:** the stored
  value is the **draw, not a boolean**, so raising the rate only ever *adds* installs, while lowering
  it drops every install whose draw exceeds the new rate and makes any cohort spanning the change
  discontinuous. If it must ever narrow, prefer user-level over event-level sampling — event-level
  silently corrupts funnels (a 10% numerator over a 100% denominator is meaningless).
- **`captureApplicationLifecycleEvents = false`** — the SDK's native lifecycle events bypass
  `AnalyticsService` entirely, so this flag is the ONLY control over them and it is all-or-nothing:
  keeping `Application Installed` also buys `Application Opened`/`Backgrounded` on every launch,
  which was most of the stream and none of the funnel. So it is off, and `main.dart` re-emits
  `Application Installed` under the SDK's own event name (reused so existing insights keep
  resolving), once per install, gated on the persisted cohort draw — which doubles as the
  first-launch marker, so installs predating the flag cannot be back-dated into a spike. The flag
  unregisters the install integration but **not** the lifecycle observer, so `$session_id` still
  works. The cost is one-directional: PostHog now sees a user only when they do one of the journey
  things, so DAU there means "did something that matters", not "opened the app" — GA4's auto
  `first_open`/`session_start` remain that record.
- **`Posthog().setup()` is not awaited** — native init must not sit on the path to first frame.
  `sessionReplay` and `surveys` stay off and no observer is installed, so there is no `$screen`.
- **Feed engagement is GA4-only.** `wallpaper_engaged` fires once per dwelled card and is the one
  genuine volume risk in the app; if PostHog volume ever needs re-checking, it is what must never
  land there. `deep_link_opened` is GA4-only for the same reason and must never feed an optimiser.
- Attempts, failures and rare account admin stay off — Crashlytics/GA4/Neon questions, which would
  make the funnel harder to read rather than the data richer. **Default-deny:** a new `track()` call
  site costs nothing until it is added to `postHogAllowedEvents`.
- **Analytics is never a ranking source.** The feed is ordered by counters counted server-side in
  `/media/signed-url` ([browse.md](browse.md)), never by `wallpaper_applied` — a sampled,
  client-reported event cannot order a feed.

## Property convention

Wallpaper funnel events carry **`wallpaper_id` + `category`**; ringtone events **`ringtone_id` +
`category`** — `category` is the browse axis, so "which collections convert" is answerable off the
events alone. Two holes before slicing: `ringtone_set_blocked_premium` sends NO properties, so the
ringtone paywall funnel cannot be split by category, and the `share_watermark_*` diagnostics carry
`wallpaper_id` + `type` only.

Static-vs-live rides along as **`type`**, spelled identically on all four wallpaper funnel events so
the funnel joins on it — a rendering hint, never a browse axis. **Analytics values are `image`/`live`
while catalog and Neon wire values are `static`/`live`**, so an event↔Neon join on `type` silently
matches nothing.

Reading these events without drawing a wrong conclusion — what `confirmed` counts, which metrics are
tripwires, where a join silently matches nothing: [analytics-ops.md](analytics-ops.md) §Reading.

## Deltas vs Pakiza — do not unify

- Gated-action keys are **`apply`/`share`**, not Pakiza's `wallpaper_apply`/`wallpaper_share` — the
  `PremiumGateAction` enum name supplies the `?source=` route param, so the short name is load-bearing.
- **`category` is ADDED alongside `type`, not a swap for it** — Arul events carry both, Pakiza
  carries `type` only and its values differ, so never join the two apps' events on it.
- `wallpaper_applied.confirmed` has no Pakiza equivalent (Pakiza carries `is_live`).
- **The PostHog LISTS are not shared.** Sync the MECHANISM (cohort gate, allow-list decorator,
  lifecycle flag off), never the contents.
- Notifications and upload are untracked in BOTH apps on purpose — a per-user event stream for a
  feature with no revenue path. Add one only if a product decision rides on it, and keep it GA4-only.
