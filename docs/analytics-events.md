# Analytics Events

Never call SDKs from widgets — always `AnalyticsService`. `CompositeAnalyticsService` fans out to:
- **PostHog** — a ~5% **user panel**, four allow-listed events. Two gates: `AnalyticsCohort` (is this install in the panel?) and `AllowlistedAnalyticsService` (is this event on the list?).
- **GA4** (`firebase_analytics`) — **every event at 100%, from every install** (raw name), plus ★ events emitting GA4 *standard* `login`/`purchase` = the Google Ads conversion source. Active when `AppConfig.firebaseEnabled` (real builds with `google-services.json`; `flutter test` skips). **The complete, unsampled record** — anything PostHog drops is still measurable here for free.
- **Meta App Events** — ONLY ★ events (clean conversion signal); installs/launches auto-logged natively. Active when `AppConfig.metaEnabled`.

★ = `login_success` (GA4 `login`) · `trial_started` (Meta StartTrial; deliberately **no** GA4
`purchase` — mapping it booked phantom revenue and double-counted the later subscriber) ·
`subscription_active` (Meta Subscribe + GA4 `purchase`), carrying `plan`, `order_id` (PhonePe merchant
order id) and `value` (INR from `app_config.prices.monthly`) for ROAS and dedupe.
The event LIST is the `track()` call sites — no table here to drift. The PostHog allow-list is pinned
as an exact set by `test/core/analytics_gating_test.dart`, so adding one is a deliberate act.
Consoles + DebugView: [analytics-ops.md](analytics-ops.md). Pakiza runs the identical mechanism with
its own event catalogue — keep the MECHANISM in sync, never the lists (§Deltas).

## PostHog cost model — why it is gated twice

PostHog bills per event on a 1M/month free tier — well under **one event per user per month** at
scale, so trimming the event *list* cannot fit inside it (`login_success` alone would blow it). The
only lever is **not sending for most users**.

- **`AnalyticsCohort` (`_rate = 0.05`)** — a persisted per-install draw gates `Posthog().setup()` itself in `main.dart`, so a non-panel install does zero PostHog init/network/battery work. User-level sampling keeps each panel member's history *complete*: funnels and retention are **exact** within the panel, scale counts by 1/rate. (Event-level sampling silently corrupts funnels — a 10% numerator over a 100% denominator is meaningless.) The stored value is the **draw, not a boolean**, so widening the rate later only ever *adds* installs and never breaks a retention curve.
- **`captureApplicationLifecycleEvents = false`** — the SDK's native lifecycle events bypass `AnalyticsService`, cannot be filtered downstream, and are the largest source of billed volume. GA4's `first_open`/`session_start` already give DAU + retention at 100% free. `sessionReplay`, `surveys` and element autocapture (no `PosthogObserver`) are off for the same reason; `screen()` is dropped by the allow-list and GA4 auto `screen_view` covers screens.
- **`Posthog().setup()` is not awaited** — native init must not sit on the critical path to first frame.
- **`feed_session_ended`** — ONE summary per feed session instead of an event per card (PostHog bills per event, not per property), flushed on app-background (the feed lives in an `indexedStack` and rarely disposes). The highest-volume billed event; look there first if the invoice moves.
- The four allowed events (`feed_session_ended` · `wallpaper_applied` · `apply_blocked_premium` · `subscription_active`) pass one filter: **"can nothing cheaper answer it?"** — GA4 is free at 100% and Neon is authoritative for users/trials/subscriptions/referrals. What survives is the sequence Neon cannot reconstruct: browsed → got value → hit the paywall → paid. Default-**deny**: a new `track()` call site costs nothing until added to `postHogAllowedEvents` in `analytics_provider.dart`.

## Property convention

Wallpaper events carry **`wallpaper_id` + `category`**; ringtone events **`ringtone_id` +
`category`** — `category` is the browse axis, so "which collections convert" is answerable off the
events alone. Static-vs-live rides along as **`type`** (`image`/`live`), spelled identically on all
four wallpaper funnel events so the funnel joins on it — a rendering hint, never a browse axis
(CLAUDE.md §5b); do not group by it the way `category` is grouped.

## Reading the data — rules that prevent wrong conclusions

- `wallpaper_applied.confirmed` is `true` only on a static apply. EVERY live apply goes through the
  OS chooser, whose final "Set" tap is unobservable — live fires `confirmed=false` on chooser-open
  (as Pakiza does). Filter `confirmed=true` for a strict completion count; **never quote the
  unfiltered number as a completion rate.**
- `link_attributed=false` (both share events) = the outgoing link carried no `referrer=` — that
  install can never be credited to the sender. A `source` that is always unattributed has its
  referral warm-up in the wrong place; it is not a surface users dislike.
- `result` is always `unavailable` on the `whatsapp` channel — the target app owns the outcome and
  never reports back. Not a failure. `channel` (`whatsapp`|`sheet`) says whether skipping the chooser
  earns its keep.
- `*_blocked_premium` fires from the client gate AND, for ringtones, from the server-refusal handler
  (lapsed subscription, stale client snapshot) — one session can emit it twice. Read as "block
  encountered", never "distinct blocks". Tracking happens at the gate; `/premium?source=` is
  display-only.
- **Revenue truth is Neon**, never a sampled analytics tool. GA4 `purchase` has TWO reporters split
  by settle location (client = app-open setup; Worker MP = app-closed trial→paid/renewals) — keep
  the split or purchases double-count ([analytics-ops.md](analytics-ops.md)).

## Deltas vs Pakiza — do not unify

- Gated-action keys are **`apply`/`share`**, not Pakiza's `wallpaper_apply`/`wallpaper_share` — the
  `PremiumGateAction` enum name supplies the `?source=` route param, so the short name is load-bearing.
- **`category` replaces Pakiza's `type`** as the second property — every saved dashboard in both
  projects is built on its own app's key.
- `wallpaper_applied.confirmed` has no Pakiza equivalent (Pakiza's in-place live swap is observable).
- Notifications and upload are untracked in BOTH apps on purpose — each would be a per-user event
  stream for a feature with no revenue path. Add events only if a product decision rides on one, and
  keep them GA4-only.
