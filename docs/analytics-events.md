# Analytics Events

Never call SDKs from widgets — always `AnalyticsService`. `CompositeAnalyticsService` fans out to:
- **PostHog** — **every install**, and **only the journey**: `Application Installed` → `login_success` → `trial_started` → `wallpaper_applied` / `wallpaper_shared` → `ringtone_set`. Nothing else reaches it (owner's call, 2026-08-18). Two gates: `AnalyticsCohort` (is this install in the panel? — currently all of them) and `AllowlistedAnalyticsService` (is this event on the list?). SDK lifecycle autocapture is **off**, so the install event is emitted by hand in `main.dart` — it is the one PostHog event that never passes through `AnalyticsService`.
- **GA4** (`firebase_analytics`) — **every event at 100%, from every install** (raw name), plus ★ events emitting GA4 *standard* `login`/`begin_checkout`. **`purchase` is NOT emitted anywhere** (2026-08-26) — `trial_started` is the ONLY Google Ads conversion source. Active when `AppConfig.firebaseEnabled` (real builds with `google-services.json`; `flutter test` skips). **The complete, unsampled record** — anything PostHog drops is still measurable here for free.
- **Meta App Events** — ONLY ★ events (clean conversion signal); installs/launches auto-logged natively. Active when `AppConfig.metaEnabled`.

★ = `login_success` (GA4 `login`) · `checkout_started` (GA4 `begin_checkout` + Meta InitiateCheckout) ·
`trial_started` (Meta StartTrial; **no** GA4 `purchase` — a trial moves no money) · `subscription_active`
(**emits NOTHING to GA4 or Meta**). `trial_started` carries `plan`, `order_id` (PhonePe merchant order
id) and `value` (INR); `login_success` only `provider`. **`trial_started` fires from the purchase poll —
or, for a trial granted APP-CLOSED (webhook resurrect, process killed behind the UPI app, poll budget
out: 13–15% of real trials vs Neon, 2026-08-26), late from `TrialConversionCatchUp` on the next `GET /me`
showing `trialing` for a `merchant_order_id` this install never reported (`late: true`, once per order;
`_trackConversion` marks BEFORE invalidating entitlement; installs predating it grandfather the trial
they find so an update cannot double-count). Same app SDK, same single source — never a server copy.**
**`checkout_started` fires at the TAP, before `/payments/initiate`**, so an initiate failure still reads as an abandoned checkout; its `method` (`upi_app`|`phonepe_sdk`) + `target_app` are what make "which UPI app expires the mandate" answerable — the question the paid funnel is actually lost on. **`payment_failed` is GA4-only** (a failure is a diagnostic; an ad optimiser fed one trains on the wrong outcome) and covers EVERY terminal exit of the purchase notifier through a single `_fail()`, so a new error path cannot silently skip it; `reason` is a short stable code, NEVER the user-facing copy — that copy is prose, it changes for wording reasons, and it would fragment the metric.
**NO PAID CONVERSION REACHES ANY AD PLATFORM (owner's call, 2026-08-26).** GA4 `purchase` + Meta
`Subscribe` are gone from BOTH sides (client mappings, `lib/ga4.ts`/`lib/meta.ts`, the
`app_instance_id`/`meta_anon_id` uploads, the `GA4_*`/`META_*` secrets). **WHY it must not come back:**
`purchase` had TWO source types — app SDK for the app-open ₹199 setup, server (GA4 MP / Meta CAPI
`system_generated`, which Meta files as a WEBSITE event) for the app-closed settle — and one conversion
with two sources desynchronises attribution: raw counts stayed right while the CAMPAIGN column ran a day
behind and undercounted. `trial_started`/StartTrial is the ONLY event campaigns bid on — app SDK, ONE
source; trial→paid is ~84%, so bidding loses nothing. **Accepted cost: no revenue/ROAS signal on either
platform.** `subscription_active` reaches **PostHog only** (server, first settle, `distinct_id` =
`users.id`) — product analytics is not an attribution source. Renewals reach nothing.
**`subscription_cancel` is server-only too** (owner 2026-08-25): one event per mandate from every channel
that ends a LIVE row — user cancel, account deletion, PhonePe revoke (cron / status poll / webhook),
permanent notify rejection — with `reason`, `prior_status`, `during_trial`. Restore-to-cancelled writes
after a failed re-setup are NOT cancels. Cancellation rate = subscription_cancel ÷ trial_started, same cohort.
The event LIST is the `track()` call sites — no table here to drift. The PostHog allow-list is pinned as
an exact set by `test/core/analytics_gating_test.dart`. Consoles + DebugView: [analytics-ops.md](analytics-ops.md).
Pakiza runs the identical mechanism with its own event catalogue — sync the MECHANISM, never the lists.

## PostHog is the journey view — and the gates that keep it that way

Two different reasons trim this stream, and confusing them leads to the wrong fix:

- **Cost** sets the COHORT. PostHog bills per event on a 1M/month free tier; sampling is a cost control,
  and there is no cost to control until the install base produces one — the 5% panel this replaced
  (2026-08-13) was sized for 800k MAU and, at real scale, was roughly ONE device that went days silent.
- **Readability** sets the LIST. The five-event list (2026-08-18) is far inside the free tier; it is short
  because install → login → trial → apply/share → ringtone set answers the only questions PostHog is asked
  here. Re-adding one is a decision, not a cleanup — the set is pinned by `analytics_gating_test.dart`.

- **`AnalyticsCohort` (`_rate = 1.0`)** — a persisted per-install draw gates `Posthog().setup()` itself in `main.dart`, so a non-panel install would do zero PostHog init/network/battery work. **Widening is safe by construction; narrowing is not.** The stored value is the **draw, not a boolean**, so raising the rate only ever *adds* installs — but lowering it drops every install whose draw exceeds the new rate, and any cohort spanning that date is discontinuous. Revisit around **30k MAU** (~25 events/user/month against the 1M tier). If it ever must narrow again, prefer user-level over event-level: event-level sampling silently corrupts funnels (a 10% numerator over a 100% denominator is meaningless).
- **`captureApplicationLifecycleEvents = false`** — the SDK's native lifecycle events bypass `AnalyticsService` entirely, so this flag is the ONLY control over them, and it is all-or-nothing: keeping `Application Installed` also buys `Application Opened`/`Backgrounded` on every launch and backgrounding, which was most of the stream and none of the funnel. So it is off, and `_startPostHog` in `main.dart` re-emits `Application Installed` under the SDK's own event name (name reused so existing insights keep resolving), once per install, gated on `AnalyticsCohort.isFreshInstall` — the persisted cohort draw doubles as the first-launch marker, which also means installs predating the flag can't be back-dated into an install spike. Verified against posthog-android 3.58.3, not assumed: turning the flag off unregisters `PostHogAppInstallIntegration` (hence the hand-emitted event) but **not** the lifecycle observer, so `$session_id` and session duration still work. The cost is real and one-directional: PostHog now sees a user only when they do one of the five things, so DAU/retention read there mean "did something that matters", not "opened the app" — GA4's auto `first_open`/`session_start`/`screen_view` remain the open-the-app record. `sessionReplay` and `surveys` stay off and no `PosthogObserver` is installed, so PostHog records no `$screen` at all; `screen()` is dropped by the allow-list.
- **`Posthog().setup()` is not awaited** — native init must not sit on the critical path to first frame.
- **Feed engagement is GA4-only.** `wallpaper_engaged` fires once per dwelled card and is the one genuine volume risk in the app; `feed_session_ended` rolls it up to one summary per feed session (flushed on app-background — every shell branch stays mounted behind `ArulBranchCrossfade`, deliberately NOT an `indexedStack`, so the feed rarely disposes). Both go to GA4 at 100% for free; neither is on the PostHog list. If PostHog volume ever needs re-checking, `wallpaper_engaged` is what must never land there. `deep_link_opened` (`kind`, `source`, id — fired once per landing by the feed / Ringtones tab / shell) is GA4-only for the same reason and is NOT a Meta ★ event: it measures which ad channel lands people, it must never feed an optimiser.
- **`subscription_active` and `referral_shared` came off with them** — revenue truth is Neon and always was. PARTIALLY REVERSED 2026-08-24 (owner): the funnel needed its real paid endpoint back, and the volume is single digits/day. It returns SERVER-side only (`workers/src/lib/posthog.ts`, first trial→paid settle) — the client allow-list stays five events and the pinned gating test is unchanged, because the client-observable `subscription_active` (repeat-subscriber setup) is a different purchase and stays off.
- Attempts, failures and rare account admin (`*_attempt`, `login_failed`, `login_cancelled`, `share_watermark_failed`, `account_delete_*`) stay off too — Crashlytics/GA4/Neon questions, which would make the funnel harder to read rather than the data richer. Default-**deny**: a new `track()` call site costs nothing until added to `postHogAllowedEvents` in `analytics_provider.dart`.
- **Analytics is never a ranking source.** The All feed is ordered by `apply_count`/`set_count` counted server-side in `/media/signed-url` (CLAUDE.md §5b) — not by `wallpaper_applied`. A sampled, client-reported event cannot order a feed, and reading one back out of PostHog to do it would be a pipeline with no owner.

## Property convention

Wallpaper FUNNEL events carry **`wallpaper_id` + `category`**; ringtone events **`ringtone_id` +
`category`** — `category` is the browse axis, so "which collections convert" is answerable off the
events alone. Two holes to know before slicing: `ringtone_set_blocked_premium` sends NO properties, so
the ringtone paywall funnel cannot be split by category, and the `share_watermark_*` diagnostics carry
`wallpaper_id` + `type` only. Static-vs-live rides along as **`type`**, spelled identically on all
four wallpaper funnel events so the funnel joins on it — a rendering hint, never a browse axis
(CLAUDE.md §5b); never group by it the way `category` is grouped. Analytics values are `image`/`live`,
catalog/Neon wire values are `static`/`live` — an event↔Neon join on `type` silently matches nothing.

## Reading the data — rules that prevent wrong conclusions

- `wallpaper_applied.confirmed` is `true` only on a static apply. EVERY live apply goes through the
  OS chooser, whose final "Set" tap is unobservable — live fires `confirmed=false` on chooser-open
  (as Pakiza does). Filter `confirmed=true` for a strict completion count; **never quote the
  unfiltered number as a completion rate.**
- `link_attributed=false` = the outgoing link carried no referral code; a WALLPAPER share still ships
  the App Link `/w/<id>` without `?ref=` (the Worker's Play redirect turns a code into `referrer=`), a
  REFERRAL share falls back to a plain store listing — either way the install can never be credited
  to the sender. A `source` that is always unattributed has its referral warm-up in the wrong place.
- `result` is always `unavailable` on the `whatsapp` channel — the target app owns the outcome and never
  reports back. Not a failure. `channel` (`whatsapp`|`sheet`) says whether skipping the chooser pays off.
- `*_blocked_premium` fires from the client gate AND from the server-refusal handler — on ALL three
  gated verbs (lapsed subscription, stale client snapshot) — so one session can emit it twice. Read as
  "block encountered", never "distinct blocks". Tracking is at the gate; `/premium?source=` is display-only.
- **Revenue truth is Neon**, never a sampled analytics tool — and now the ONLY revenue record, since no
  `purchase`/`Subscribe` reaches GA4 or Meta. Delivery proof without console access: the Worker writes
  `ph:subscription_active:<txn>` to KV **only** on an accepted send, stamped with the row's RETURNED
  `updated_at`, not `now()` — PostHog dedupes on `[timestamp, distinct_id, event, uuid]`, so a wall-clock
  stamp had made the deterministic `uuid` inert.

## Deltas vs Pakiza — do not unify

- Gated-action keys are **`apply`/`share`**, not Pakiza's `wallpaper_apply`/`wallpaper_share` — the
  `PremiumGateAction` enum name supplies the `?source=` route param, so the short name is load-bearing.
- **`category` is ADDED alongside `type`, not a swap for it** — Arul events carry both, Pakiza carries
  `type` only, and its values (`staticWallpaper`/`live`) differ from Arul's, so never join the two
  apps' events on it. Every saved dashboard in both projects is built on its own app's key.
- `wallpaper_applied.confirmed` has no Pakiza equivalent (Pakiza carries `is_live`); both apps' live
  apply goes through the same unobservable OS chooser.
- **The PostHog LISTS are not shared.** Arul's is the five-event journey (2026-08-18); Pakiza's is four
  cost-trimmed events at a 5% cohort. Sync the MECHANISM (cohort gate, allow-list decorator, lifecycle
  flag off), never the contents. Pakiza has no hand-emitted install event.
- Notifications and upload are untracked in BOTH apps on purpose — a per-user event stream for a
  feature with no revenue path. Add events only if a product decision rides on one; keep them GA4-only.
