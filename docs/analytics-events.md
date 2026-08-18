# Analytics Events

Never call SDKs from widgets — always `AnalyticsService`. `CompositeAnalyticsService` fans out to:
- **PostHog** — **every install**, and **only the journey**: `Application Installed` → `login_success` → `trial_started` → `wallpaper_applied` / `wallpaper_shared` → `ringtone_set`. Nothing else reaches it (owner's call, 2026-08-18). Two gates: `AnalyticsCohort` (is this install in the panel? — currently all of them) and `AllowlistedAnalyticsService` (is this event on the list?). SDK lifecycle autocapture is **off**, so the install event is emitted by hand in `main.dart` — it is the one PostHog event that never passes through `AnalyticsService`.
- **GA4** (`firebase_analytics`) — **every event at 100%, from every install** (raw name), plus ★ events emitting GA4 *standard* `login`/`purchase` = the Google Ads conversion source. Active when `AppConfig.firebaseEnabled` (real builds with `google-services.json`; `flutter test` skips). **The complete, unsampled record** — anything PostHog drops is still measurable here for free.
- **Meta App Events** — ONLY ★ events (clean conversion signal); installs/launches auto-logged natively. Active when `AppConfig.metaEnabled`.

★ = `login_success` (GA4 `login`) · `trial_started` (Meta StartTrial; deliberately **no** GA4
`purchase` — mapping it booked phantom revenue and double-counted the later subscriber) ·
`subscription_active` (Meta Subscribe + GA4 `purchase`). The two PURCHASE events carry `plan`,
`order_id` (PhonePe merchant order id) and `value` (INR from `app_config.prices.monthly`) for ROAS and
for matching the Worker's copy; `login_success` carries only `provider`.
The event LIST is the `track()` call sites — no table here to drift. The PostHog allow-list is pinned
as an exact set by `test/core/analytics_gating_test.dart`, so adding one is a deliberate act.
Consoles + DebugView: [analytics-ops.md](analytics-ops.md). Pakiza runs the identical mechanism with
its own event catalogue — keep the MECHANISM in sync, never the lists (§Deltas).

## PostHog is the journey view — and the gates that keep it that way

Two different reasons trim this stream, and confusing them leads to the wrong fix:

- **Cost** sets the COHORT. PostHog bills per event on a 1M/month free tier; sampling is a cost
  control, and there is no cost to control until the install base produces one — the 5% panel this
  replaced (2026-08-13) was sized for 800k MAU and, at the app's real scale, meant a panel of roughly
  ONE device that went days without an event.
- **Readability** sets the LIST. The five-event list (2026-08-18) is far inside the free tier; it is
  short because a stream that shows install → login → trial → apply/share → ringtone set and nothing
  else answers the only questions PostHog is asked here. Re-adding an event is a decision, not a
  cleanup — the exact set is pinned by `test/core/analytics_gating_test.dart`.

- **`AnalyticsCohort` (`_rate = 1.0`)** — a persisted per-install draw gates `Posthog().setup()` itself in `main.dart`, so a non-panel install would do zero PostHog init/network/battery work. **Widening is safe by construction; narrowing is not.** The stored value is the **draw, not a boolean**, so raising the rate only ever *adds* installs — but lowering it drops every install whose draw exceeds the new rate, and any cohort spanning that date is discontinuous. Revisit around **30k MAU** (~25 events/user/month against the 1M tier). If it ever must narrow again, prefer user-level over event-level: event-level sampling silently corrupts funnels (a 10% numerator over a 100% denominator is meaningless).
- **`captureApplicationLifecycleEvents = false`** — the SDK's native lifecycle events bypass `AnalyticsService` entirely, so this flag is the ONLY control over them, and it is all-or-nothing: keeping `Application Installed` also buys `Application Opened`/`Backgrounded` on every launch and backgrounding, which was most of the stream and none of the funnel. So it is off, and `_startPostHog` in `main.dart` re-emits `Application Installed` under the SDK's own event name (name reused so existing insights keep resolving), once per install, gated on `AnalyticsCohort.isFreshInstall` — the persisted cohort draw doubles as the first-launch marker, which also means installs predating the flag can't be back-dated into an install spike. Verified against posthog-android 3.58.3, not assumed: turning the flag off unregisters `PostHogAppInstallIntegration` (hence the hand-emitted event) but **not** the lifecycle observer, so `$session_id` and session duration still work. The cost is real and one-directional: PostHog now sees a user only when they do one of the five things, so DAU/retention read there mean "did something that matters", not "opened the app" — GA4's auto `first_open`/`session_start`/`screen_view` remain the open-the-app record. `sessionReplay` and `surveys` stay off and no `PosthogObserver` is installed, so PostHog records no `$screen` at all; `screen()` is dropped by the allow-list.
- **`Posthog().setup()` is not awaited** — native init must not sit on the critical path to first frame.
- **Feed engagement is GA4-only.** `wallpaper_engaged` fires once per dwelled card and is the one genuine volume risk in the app; `feed_session_ended` rolls it up to one summary per feed session (flushed on app-background — every shell branch stays mounted behind `ArulBranchCrossfade`, deliberately NOT an `indexedStack`, so the feed rarely disposes). Both go to GA4 at 100% for free; neither is on the PostHog list. If PostHog volume ever needs re-checking, `wallpaper_engaged` is what must never land there.
- **`subscription_active` and `referral_shared` came off with them.** Revenue truth is Neon and always was — `subscription_active` only ever existed here so the funnel had an endpoint, and `trial_started` is that endpoint now.
- Attempts, failures and rare account admin (`*_attempt`, `login_failed`, `login_cancelled`, `share_watermark_failed`, `account_delete_*`) stay off too — Crashlytics/GA4/Neon questions, which would make the funnel harder to read rather than the data richer. Default-**deny**: a new `track()` call site costs nothing until added to `postHogAllowedEvents` in `analytics_provider.dart`.
- **Analytics is never a ranking source.** The All feed is ordered by `apply_count`/`set_count` counted server-side in `/media/signed-url` (CLAUDE.md §5b) — not by `wallpaper_applied`. A sampled, client-reported event cannot order a feed, and reading one back out of PostHog to do it would be a pipeline with no owner.

## Property convention

Wallpaper FUNNEL events carry **`wallpaper_id` + `category`**; ringtone events **`ringtone_id` +
`category`** — `category` is the browse axis, so "which collections convert" is answerable off the
events alone. Two holes to know before slicing: `ringtone_set_blocked_premium` sends NO properties, so
the ringtone paywall funnel cannot be split by category, and the `share_watermark_*` diagnostics carry
`wallpaper_id` + `type` only. Static-vs-live rides along as **`type`**, spelled identically on all
four wallpaper funnel events so the funnel joins on it — a rendering hint, never a browse axis
(CLAUDE.md §5b); do not group by it the way `category` is grouped. Its analytics values are
`image`/`live` while the catalog/Neon wire values are `static`/`live`, so an event↔Neon join on `type`
silently matches nothing.

## Reading the data — rules that prevent wrong conclusions

- `wallpaper_applied.confirmed` is `true` only on a static apply. EVERY live apply goes through the
  OS chooser, whose final "Set" tap is unobservable — live fires `confirmed=false` on chooser-open
  (as Pakiza does). Filter `confirmed=true` for a strict completion count; **never quote the
  unfiltered number as a completion rate.**
- `link_attributed=false` = the outgoing link carried no referral code, and the two share events
  degrade differently: a WALLPAPER share still ships the App Link `/w/<id>`, only without `?ref=`
  (the Worker's Play redirect is what turns a code into `referrer=`), while a REFERRAL share falls
  back to a plain store listing. Either way that install can never be credited to the sender. A `source` that is always unattributed has its
  referral warm-up in the wrong place; it is not a surface users dislike.
- `result` is always `unavailable` on the `whatsapp` channel — the target app owns the outcome and
  never reports back. Not a failure. `channel` (`whatsapp`|`sheet`) says whether skipping the chooser
  earns its keep.
- `*_blocked_premium` fires from the client gate AND from the server-refusal handler — on ALL three
  gated verbs, not just ringtones (lapsed subscription, stale client snapshot) — so one session can
  emit it twice. Read as "block
  encountered", never "distinct blocks". Tracking happens at the gate; `/premium?source=` is
  display-only.
- **Revenue truth is Neon**, never a sampled analytics tool. GA4 `purchase` has TWO reporters split
  by settle location (client = app-open setup; Worker MP = app-closed trial→paid/renewals) — keep
  the split or purchases double-count. Nothing downstream catches an overlap: GA4's `transaction_id`
  dedupe covers WEB streams only, and Arul's Worker report is an app stream
  ([analytics-ops.md](analytics-ops.md)).

## Deltas vs Pakiza — do not unify

- Gated-action keys are **`apply`/`share`**, not Pakiza's `wallpaper_apply`/`wallpaper_share` — the
  `PremiumGateAction` enum name supplies the `?source=` route param, so the short name is load-bearing.
- **`category` is ADDED alongside `type`, not a swap for it** — Arul events carry both, Pakiza carries
  `type` only, and its values (`staticWallpaper`/`live`) differ from Arul's, so never join the two
  apps' events on it. Every saved dashboard in both projects is built on its own app's key.
- `wallpaper_applied.confirmed` has no Pakiza equivalent — Pakiza's event carries `is_live` instead.
  Both apps' live apply goes through the same unobservable OS chooser.
- **The PostHog LISTS are not shared.** Arul's is the five-event journey (2026-08-18); Pakiza's is its
  own four cost-trimmed events at a 5% cohort. Keep the MECHANISM in sync — cohort gate, allow-list
  decorator, lifecycle flag off — never the contents. Pakiza has no hand-emitted install event.
- Notifications and upload are untracked in BOTH apps on purpose — each would be a per-user event
  stream for a feature with no revenue path. Add events only if a product decision rides on one, and
  keep them GA4-only.
