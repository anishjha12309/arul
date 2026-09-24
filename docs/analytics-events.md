# Analytics Events

**Never call SDKs from widgets — always `AnalyticsService`**, which fans out to three sinks. Consoles
and reading the data: [analytics-ops.md](analytics-ops.md). Ads traps: [google-ads.md](google-ads.md).

- **PostHog** — every PLAY install, and **only the journey**: `Application Installed` → `login_success` →
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
the server (GA4 MP; Meta CAPI, filed as a WEBSITE event) for the app-closed settle — reconciling on
different schedules, so the Ads CAMPAIGN column ran a day behind and undercounted while GA4's raw
counts stayed right. **`trial_started`/StartTrial is the ONLY event campaigns bid on** — app SDK,
in-session, one source. **Accepted cost: no revenue or ROAS signal on either platform. Revenue truth
is Neon.**

`trial_started` carries `plan`, `order_id`, `value`, and — when the SAME process ran the checkout —
`method` and `target_app`; a late catch-up copy omits both rather than guess. It fires from the purchase poll — or, for a
trial granted APP-CLOSED (webhook resurrect, process killed behind the UPI app, poll budget out),
late from `TrialConversionCatchUp` on the next `GET /me` showing `trialing` for an order this install
never reported (`late: true`, once per order). The catch-up marks BEFORE invalidating entitlement and
installs predating it grandfather the trial they find, so an update cannot double-count. **Same app
SDK, one source — never a server copy.**

`subscription_active` reaches **PostHog only** (server, first trial→paid settle) — product analytics
is not an attribution source; renewals reach nothing. It carries `target_app` from the row's
`upi_target_app` (`unknown` for rows older than the column) — the SAME key `checkout_started` and
`trial_started` carry, so "which UPI app starts, completes and expires a mandate" is one axis. `subscription_cancel` is server-only too:
one event per mandate from every channel that ends a LIVE row, carrying `reason`, `prior_status` and
`during_trial`. Restore-to-cancelled writes after a failed re-setup are NOT cancels.

## The sign-in diagnostics

`login_attempt`, `login_cancelled` and `login_failed` are on the PostHog allow-list as a **diagnostic exception** to
the journey-only rule; taking them off is the owner's call. An attempt with no cancel, success or
failure is a process that died under Google's picker — the only way that loss is visible. Both carry `gis_code`,
`ms_since_authenticate` and `surface`. `login_cancelled` adds `nudge` (the classified outcome; the
screen shows one retry line whatever it is) and `ms_to_surface`, carried by `login_success` too — the slow-surface split needs a
succeeding population for its denominator. Both: [auth.md](auth.md).
`login_surface_shown` (once per attempt, `surface`/`auto`/`ms_to_surface`) proves Google's screen
appeared — for the installs with no outcome at all it splits "never saw the sheet" from "saw it and
left". `surface` values: `sheet`, `sheet_return` (the automatic attempt a return to the wall
re-armed), `sheet_reconnect` (the one the link coming back after a network-class failure re-armed;
a return outranks it), `button`, `button_after_dismiss`, `button_after_add_account` (the picker the
guard reopens once after Google's add-account flow); a re-armed attempt that escalates to the picker
carries its sheet's name on its `login_attempt` only. **PostHog sends every event immediately (`flushAt = 1`)**: the default 20-event/30 s batch
lost the install and the sign-in outcome of everyone who left inside that window, which is how 6 in
100 installs read as "install, then nothing". Expect the measured install→login rate to read LOWER
from build 74 on — the denominator now includes people it used to miss.
Every sign-in event also carries **`install_channel`** (`google_ads` / `meta_ads` / `organic` /
`share` / `link` / `other` / `unknown`, off the Play referrer, `install_utm_source` and
`install_utm_campaign` beside it; an install that arrived on a wallpaper or ringtone link adds
`+wallpaper` / `+ringtone` to the SAME value — split on `+`, never compare the whole string) and **`low_ram`** (the poster rule's verdict) — the two cuts
PostHog's own properties cannot make, on the events that exist rather than new ones.

**The two events spell the Credential Manager message differently: `login_cancelled` carries
`description`, `login_failed` carries `error`.** A query that splits "on `description`" returns
nothing for `login_failed`. Why the split matters at all — the mixed-bucket problem — is in
[auth.md](auth.md).

The sign-in SURFACE split is GA4-only, deliberately not on the PostHog list:
`login_attempt{provider, surface, auto}` once per attempt, carrying the FIRST surface tried, and
`sheet_unavailable{gis_code, description, ms_since_authenticate}` when the sheet could not RUN and the
button took over. A sheet that drew nothing emits nothing — nothing failed. Free-text values stay ≤100
chars; GA4 silently drops longer ones.

## The rest of the catalogue

`checkout_started` fires at the TAP, before `/payments/initiate`, so an initiate failure still reads
as an abandoned checkout. Its `method` (`upi_app`|`phonepe_sdk`|`upi_qr`) and `target_app` answer "which
UPI app expires the mandate" — where the paid funnel is actually lost. `upi_qr` carries NO
`target_app`: the package it named was never launched and the approval may land on another phone, so
reporting it would corrupt that ranking. It is a bare string literal, not
an `ArulEvents` constant.

`paywall_shown` reports the sell ONCE the installed-app probe has ANSWERED — the list arrives
asynchronously, and reporting the first build stamps `has_upi_app: no` on every install that ever
opened the paywall. **GA4-only**, pinned off the PostHog list by the gating test. It answers which
UPI apps a user was actually offered: `has_upi_app`, `upi_app_count`, `upi_apps` (short codes,
**sorted** — the picker floats the remembered app to the head, and picker order would file one
installed set under every rotation of it), `default_app`, plus `upi_other_count` and `upi_others` — the mandate handlers the
phone HAS and the allowlist refuses, as RAW package names (a code would hide the very names this
exists to learn) packed to whole entries inside the 100-char limit, with the count surviving any
truncation. `has_upi_app: no` beside a non-zero count is not a phone that cannot pay, it is one we
declined to sell to, and those two were indistinguishable. Then `trial_eligible`, `variant`
(`trial`|`paid`|`resubscribe`|`unknown`, the last being an entitlement that would not load) and
`paywall_source`, the gate verb (`post_signin` = the after-sign-in paywall test, whose side also rides
`login_success` as `paywall_test`) — GA4 owns the bare `source` as a traffic dimension. **Every value
is a string**: GA4 parses no numeric parameter into an event-scoped custom dimension on APP streams
and the sink coerces a bool to 1/0, so a count sent as a number is collected and can never be broken
down. It repeats inside one visit only when the installed SET changes, which is the only proof the
install prompt ever works.

`payment_failed` is GA4-only (a failure is a diagnostic; an ad optimiser fed one trains on the wrong
outcome) and covers EVERY terminal exit of the purchase notifier through one `_fail()`, so a new error
path cannot silently skip it. **`reason` is a short stable code, NEVER the user-facing copy**, which
is prose and would fragment the metric. `network_error` is a dead link on the initiate after its
retries; `unexpected_error` is what is left — a genuine defect, also recorded to Crashlytics — so
never compare it across the split. A resumable intent that ends without approval says
`intent_app_switched` (the user picked ANOTHER UPI app — there is no start-over button) or
`intent_resume_expired` (the link's deadline); a PhonePe verdict stays `expired`. All three are
silent on screen: the event counts it, the user sees no failure. Once the resume button was used, `method` reads `upi_app_resumed` on
`trial_started`, `subscription_active` and `payment_failed` — `checkout_started` keeps `upi_app` and
fires once per decision, never on a resume.

The return page adds `trial_return_shown` (once per open) and `return_video_start`/`return_video_muted`
beside `onboarding_video_*` — all GA4-only, `lang` = the cut that PLAYED (`hi` plays `en`). A tap
from that page stamps `surface: return` on `checkout_started`, `trial_started`, `subscription_active`
and `payment_failed`; the trial screen sends no `surface`, so an absent key IS the trial screen. The
sign-in events use the same parameter name for their own values — filter by event before splitting.

The event LIST is the `track()` call sites — no table here to drift. The ★ NAMES and the PostHog
allow-list are exact sets pinned by tests: every sink matches the literal, a typo drops silently.

## PostHog is the journey view — and the gates that keep it that way

Two different reasons trim this stream; confusing them leads to the wrong fix. **Cost sets the
COHORT** (PostHog bills per event, 1M/month free). **Readability sets the LIST** — install → login →
trial → apply/share → ringtone set answers the only questions PostHog is asked here. Re-adding an
event is a decision, not a cleanup.

- **NO SIDELOADED BUILD REPORTS TO POSTHOG** (owner's rule) — `PlayInstall` gates the sink, GA4/Meta/
  Crashlytics deliberately not. Why and how it fails: [analytics-ops.md](analytics-ops.md).
- **`AnalyticsCohort` gates `Posthog().setup()` itself**, so a non-panel install does zero PostHog
  work. **Widening is safe by construction; narrowing is not:** the stored value is the **draw, not a
  boolean**, so raising the rate only ever *adds* installs, while lowering it drops every install
  whose draw exceeds the new rate and makes any cohort spanning the change discontinuous. If it must
  narrow, prefer user-level over event-level sampling — event-level silently corrupts funnels (a 10%
  numerator over a 100% denominator is meaningless).
- **`captureApplicationLifecycleEvents = false`** — the SDK's lifecycle events bypass
  `AnalyticsService`, and the flag is all-or-nothing: keeping `Application Installed` also buys
  `Opened`/`Backgrounded` on every launch (most of the stream, none of the funnel). So it is off and
  `main.dart` re-emits `Application Installed` under the SDK's own name (existing insights keep
  resolving), once per install, gated on the persisted cohort draw — the first-launch marker, so old
  installs cannot be back-dated into a spike. The flag leaves the lifecycle observer, so `$session_id`
  still works. PostHog DAU therefore means "did a journey thing", not "opened the app" — GA4's auto
  `first_open`/`session_start` remain that record.
- **`Posthog().setup()` is not awaited** — native init must not sit on the path to first frame.
  `sessionReplay`/`surveys` off, no observer, so there is no `$screen`.
- **Feed engagement is GA4-only.** `wallpaper_engaged` fires once per dwelled card — the one genuine
  volume risk in the app, and the thing that must never land in PostHog. `deep_link_opened` is
  GA4-only for the same reason and must never feed an optimiser.
- Failures and rare account admin stay off — Crashlytics/GA4/Neon questions. **Default-deny:** a new
  `track()` call site costs nothing until it is on `postHogAllowedEvents`.
- **Analytics is never a ranking source.** The feed is ordered by counters counted server-side in
  `/media/signed-url` ([browse.md](browse.md)), never by `wallpaper_applied` — a sampled,
  client-reported event cannot order a feed.

## Property convention

Wallpaper funnel events carry **`wallpaper_id` + `category`**; ringtone events **`ringtone_id` +
`category`** — `category` is the browse axis, so "which collections convert" is answerable off the
events alone. Two holes before slicing: `ringtone_set_blocked_premium` sends NO properties, so that
paywall funnel cannot split by category, and `share_watermark_*` carries `wallpaper_id` + `type`.

Static-vs-live rides along as **`type`**, spelled identically on all four wallpaper funnel events so
the funnel joins on it — a rendering hint, never a browse axis. **Analytics values are `image`/`live`
while catalog and Neon wire values are `static`/`live`**, so an event↔Neon join on `type` silently
matches nothing.

**`app_language`, `language_source` and `geo_region` ride EVERY event via `AnalyticsService.register`,
never only `identify`** — a person property, frozen at ingest, leaves every pre-login event blank;
`reset()` clears them on sign-out, so each sink re-applies them.
**The PostHog sink also stamps them onto the capture itself**, primed from prefs before `setup()`:
the sheet-first `login_attempt` lands before the `register` round trip, and the SDK alone left it
blank on four cold-start attempts in five. A blank `app_language` bucket is installs that predate the
register, cold-start attempts before that stamp, and the Worker's server-side events.

`language_source` (`pick` · `link` · `geo` · `phone` · `default`) and `geo_region` (Cloudflare's raw
region or `none`) measure the region default. A fresh install's install event and first-frame
`login_attempt` fire BEFORE `GET /geo` answers, so they carry the phone's language and `phone`; later
events carry `geo`. An older stored pick reads `pick`. GA4 hides both until registered as user-scoped
custom dimensions.

Reading these without a wrong conclusion — what `confirmed` counts, which metrics are tripwires,
where a join silently matches nothing: [analytics-ops.md](analytics-ops.md) §Reading.

## Deltas vs Pakiza — do not unify

- Gated-action keys are **`apply`/`share`**, not Pakiza's `wallpaper_apply`/`wallpaper_share` — the
  `PremiumGateAction` enum name supplies the `?source=` route param, so the short name is load-bearing.
- **`category` is ADDED alongside `type`, not a swap for it** — Arul events carry both, Pakiza
  carries `type` only and its values differ, so never join the two apps' events on it.
- `wallpaper_applied.confirmed` has no Pakiza equivalent (Pakiza carries `is_live`).
- **The PostHog LISTS are not shared.** Sync the MECHANISM (cohort gate, allow-list decorator,
  lifecycle flag off), never the contents.
- Upload is untracked on purpose — no revenue path. Campaign push has exactly two events, both
  GA4-only and off the PostHog list: `push_opened` on a tap and `push_permission` on the one prompt.
  The CMS's "Opened" number reads Neon's `push_opens`, never GA4 — one conversion, one source
  ([push.md](push.md)).
