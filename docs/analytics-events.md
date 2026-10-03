# Analytics events

**Never call an SDK from a widget — always `AnalyticsService`**, which fans out to three sinks. Consoles,
the Play-install gate and reading the data: [analytics-ops.md](analytics-ops.md) · Ads:
[google-ads.md](google-ads.md). The event list is the `track()` call sites; the ★ names and the PostHog
allow-list are exact sets pinned by tests — a typo drops silently.

- **PostHog** — PLAY installs only, and **only the journey** (`login_success` → `trial_started` →
  `wallpaper_applied`/`wallpaper_shared` → `ringtone_set`) plus the two exceptions below. Gated by
  `AnalyticsCohort` (is this install in the panel?) and `AllowlistedAnalyticsService` (is the event on
  the list?). `Application Installed` is emitted by hand in `main.dart` — the one PostHog event that
  bypasses `AnalyticsService`.
- **GA4** — **every event at 100%, from every install**, under its raw name, plus ★ events as GA4
  *standard* `login`/`begin_checkout`. The complete record.
- **Meta App Events** — ★ events only; installs and launches are auto-logged natively.

★ = `login_success` (GA4 `login`, Meta CompleteRegistration) · `checkout_started` (GA4 `begin_checkout`,
Meta InitiateCheckout) · `trial_started` (Meta StartTrial).

## ONE conversion action, ONE data source — never re-open this

**No paid conversion reaches any ad platform** (owner). GA4 `purchase` and Meta `Subscribe` are gone
from both sides — client mappings, the Worker's GA4-MP and Meta-CAPI reporters, their id uploads and
secrets. `purchase` had TWO source types (the app SDK for the app-open setup, the server for the
app-closed settle) reconciling on different schedules, so the Ads campaign column ran a day behind and
undercounted while GA4's raw counts looked right. **`trial_started`/StartTrial is the ONLY event
campaigns bid on** — app SDK, in-session, one source. Accepted cost: no revenue or ROAS signal
anywhere. Revenue truth is Neon.

`trial_started` carries `plan`, `order_id`, `value` and — only when the SAME process ran the checkout —
`method` and `target_app`. **Never omit `value`** (₹199 before `app_config` lands): Ads books a
valueless conversion at ₹1. It fires from the purchase poll or, for a trial granted APP-CLOSED (webhook
resurrect, process killed behind the UPI app, poll budget out), late from `TrialConversionCatchUp` on
the next `GET /me` showing `trialing` for an order this install never reported (`late: true`, once per
order). The catch-up marks BEFORE invalidating entitlement and fires only once its marker is open (a
no-trial read or the checkout tap): a trial found on a reinstall or second phone is recorded, never
fired — GA4 does not dedupe a custom event, and the copy would credit the reinstall's ad.

`subscription_active` (first trial→paid settle) and `subscription_cancel` (one per mandate, from every
channel that ends a LIVE row, with `reason`, `prior_status`, `during_trial`) are server-side and reach
**PostHog only** — product analytics, never an attribution source; renewals reach nothing. A
restore-to-cancelled after a failed re-setup is NOT a cancel. `subscription_active` carries
`target_app` from `upi_target_app` — the SAME key `checkout_started` and `trial_started` carry, so
"which UPI app starts, completes and expires a mandate" is one axis.

## The sign-in diagnostics

`login_attempt`, `login_surface_shown`, `login_cancelled` and `login_failed` are on the PostHog list as
a **diagnostic exception** to the journey rule; taking them off is the owner's call. An attempt with no
outcome is a process that died under Google's surface — the only way that loss is visible.
`login_surface_shown` (once per attempt) splits "never saw the sheet" from "saw it and left".

- Outcomes carry `gis_code`, `ms_since_authenticate` and `surface`; `login_cancelled` adds `nudge` (the
  classified outcome) and `ms_to_surface`, which `login_success` carries too as the denominator. The
  message field names and how to read the buckets: [auth.md](auth.md) §Reading the failure buckets.
- `surface`: `sheet`, `sheet_return`, `sheet_reconnect`, `sheet_after_offline` (a return outranks it,
  it outranks a reconnect), `button`, `button_after_dismiss`, `button_after_add_account`, `button_after_offline` (a parked tap). A re-armed
  attempt that escalates to the picker carries its sheet's name on its `login_attempt` only. The stall
  guard's abandons are `login_failed.kind`: `stalled`, `stalled_resumed`, `surface_stripped`.
  `sheet_unavailable` (GA4-only) fires when the sheet could not RUN.
- **`flushAt = 1`** — PostHog's default 20-event/30 s batch lost the install and sign-in outcome of
  everyone who left inside that window.
- Sign-in events carry **`install_channel`** (`google_ads` / `meta_ads` / `organic` / `share` /
  `link` / `other` / `unknown`, off the Play referrer, with `install_utm_source`/`_campaign` beside it)
  — bar a fresh install's first `login_attempt`, which fires before Play answers; sign-in never waits.
  Play carries only same-session clicks, so an `organic`/`unknown`/`other` install is relabelled
  `meta_ads` when Meta's Install Referrer (`MetaInstallReferrer.kt`) holds a view-through or
  later-session touch. A wallpaper or ringtone link adds `+wallpaper`/`+ringtone` to the SAME value —
  split on `+`, never compare the whole string. Also **`low_ram`** (the poster rule's verdict).
- Free-text values stay ≤100 chars; GA4 silently drops longer ones.

## The checkout and paywall events (GA4-only)

- `checkout_started` fires at the TAP, before `/payments/initiate`, so an initiate failure still reads
  as an abandoned checkout. `method` (`upi_app`|`phonepe_sdk`|`upi_qr`) and `target_app`; `upi_qr`
  carries NO `target_app` — the named package never launched and the approval may land on another
  phone. Once the resume button is used, `method` reads `upi_app_resumed` on `trial_started`,
  `subscription_active` and `payment_failed`; `checkout_started` fires once per decision, never on a
  resume.
- `paywall_shown`, `payment_failed` and their value rules: [checkout.md](checkout.md) §Events.
- Offer checkout events carry `offer: cancel_99` + `price_paise`; that `checkout_started` is never
  `begin_checkout`/InitiateCheckout (a switch is no conversion).
- The return page adds `trial_return_shown` and `return_video_start`/`return_video_muted`; a tap from
  it stamps `surface: return` on the checkout events (absent = the trial screen). The sign-in events use
  `surface` for their own values — filter by event before splitting.
- Campaign push has two events, `push_opened` and `push_permission`, GA4-only; the CMS's Opened number
  reads Neon's `push_opens`, never GA4. Upload is untracked on purpose.

## PostHog is the journey view — keep it that way

**Cost sets the COHORT** (PostHog bills per event); **readability sets the LIST** — re-adding an event is
a decision, not a cleanup. **The event count is fixed (owner): new signal rides existing events** as a
property, a `register()` super property or a person property — [analytics-signal.md](analytics-signal.md).

- **`AnalyticsCohort` gates `Posthog().setup()` itself.** The stored value is the **draw, not a
  boolean**, so raising the rate only ever adds installs; lowering it drops every install whose draw
  exceeds the new rate and breaks any cohort spanning the change. If it must narrow, sample users,
  never events — a 10% numerator over a 100% denominator is meaningless.
- **`captureApplicationLifecycleEvents = false`** — the flag is all-or-nothing, and keeping
  `Application Installed` bought `Opened`/`Backgrounded` on every launch. `main.dart` re-emits
  `Application Installed` under the SDK's own name once per install, gated on the persisted draw, so old
  installs cannot be back-dated into a spike. PostHog DAU means "did a journey thing"; GA4's
  `first_open`/`session_start` are the "opened the app" record.
- `Posthog().setup()` is not awaited — native init stays off the first-frame path.
- **The cancel funnel is on the list** (owner exception): `cancel_tapped`, `cancel_offer_*`,
  `cancel_confirmed`/`_kept`, `resubscribe_tapped`; `flow: winback` = a comeback.
  `_accepted` = the tap; `_switched` = ₹99 live.
- **Feed engagement is GA4-only.** `wallpaper_engaged` (once per dwelled card) is the one real volume
  risk; `deep_link_opened` stays off too and must never feed an optimiser.
- **Analytics never ranks the feed**; Neon counters do ([browse.md](browse.md)).

## Property conventions

- Wallpaper funnel events carry **`wallpaper_id` + `category`**, ringtone events **`ringtone_id` +
  `category`**. Holes: `ringtone_set_blocked_premium` sends no properties; `share_watermark_*` carries
  `wallpaper_id` + `type`.
- **`type` is `image`/`live` in analytics but `static`/`live` in the catalog and Neon** — an event↔Neon
  join on `type` silently matches nothing.
- Gated-action keys are `apply`/`share`: the `PremiumGateAction` enum name supplies the `?source=` route
  param, so the short name is load-bearing.
- **`app_language`, `language_source` and `geo_region` ride EVERY event via `register`, never only
  `identify`** — a person property leaves every pre-login event blank. PostHog's reset strips super
  properties, so that sink re-applies them, and it also stamps them onto the capture itself, primed from
  prefs before `setup()` — the first `login_attempt` lands before `register`. `reset()` runs on sign-out,
  deletion and a dead session, before the wall. **GA4's reset is `setUserId(null)`, never `resetAnalyticsData`**,
  which mints a new app instance id and cuts the Ads attribution of a re-login.
- `language_source` (`pick`·`link`·`geo`·`phone`·`default`; `geo` = an older build's region language)
  and `geo_region` (Cloudflare's region or `none`, `none` until `GET /geo` answers). GA4 hides both
  until registered as user-scoped custom dimensions.
- **`exp_regional` (`control`|`regional`)** is the ENDED regional A/B: no new install is dealt an arm;
  installs dealt one keep stamping it (registered like `app_language`, the ASSIGNMENT, not the kill
  state). `feature_flags.exp_regional = false` still switches the regional wall off from the next cold
  start.
