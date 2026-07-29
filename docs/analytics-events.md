# Analytics Events

Never call SDKs from widgets — always `AnalyticsService`. `CompositeAnalyticsService` fans out to:
- **PostHog** — a ~5% **user panel**, four allow-listed events. Two gates: `AnalyticsCohort` (is this install in the panel?) and `AllowlistedAnalyticsService` (is this event on the list?).
- **GA4** (`firebase_analytics`) — **every event at 100%, from every install** (raw name), plus ★ events emitting GA4 *standard* `login`/`purchase` = the Google Ads conversion source. Active when `AppConfig.firebaseEnabled` (real builds with `google-services.json`; `flutter test` skips). Auto-collects first_open/session_start/screen_view. **This is the complete, unsampled record** — anything PostHog drops is still measurable here for free.
- **Meta App Events** — ONLY ★ events (clean conversion signal); installs/launches auto-logged natively. Active when `AppConfig.metaEnabled` (real `META_APP_ID` + `META_CLIENT_TOKEN` dart-defines).

Consoles, DebugView and the Google Ads wiring: [analytics-ops.md](analytics-ops.md).
Pakiza runs the identical mechanism with its own event catalogue — keep the mechanism in sync, not the lists (see [Deltas vs Pakiza](#deltas-vs-pakiza)).

## PostHog cost model — why it is gated twice

PostHog bills per event on a 1M/month free tier. Spread over a large user base that is well under
**one event per user per month**, so trimming the event *list* cannot fit inside it — `login_success`
alone, once per user, would blow it. The only lever that works is **not sending for most users**.

- **`AnalyticsCohort` (`_rate = 0.05`)** — a persisted per-install draw decides panel membership, and gates `Posthog().setup()` itself in `main.dart`, so a non-panel install does zero PostHog init/network/battery work. User-level sampling keeps each panel member's history *complete*, so funnels and retention are **exact** within the panel; scale absolute counts by 1/rate. (Event-level sampling silently corrupts funnels: a 10% numerator over a 100% denominator is meaningless.) The stored value is the **draw, not a boolean**, so widening the rate later only ever *adds* installs and never breaks a retention curve.
- **`captureApplicationLifecycleEvents = false`** — the SDK's `Application Opened`/`Backgrounded`/`Installed`/`Updated` fire natively, never pass through `AnalyticsService`, and so cannot be filtered downstream. They are the single largest source of billed volume. GA4's `first_open`/`session_start` already give DAU + retention across 100% of installs for free. `sessionReplay` and `surveys` are off for the same reason, and no `PosthogObserver`/`PostHogWidget` is installed, so there is no element autocapture either.
- **`Posthog().setup()` is not awaited** — native init and the SDK's first network work must not sit on the critical path to the first frame. Nothing captures before the first user action anyway.
- **`feed_session_ended`** — ONE summary per feed session instead of one `wallpaper_engaged` per card. PostHog bills per event, **not per property**. Flushed on app-background (the feed lives in a `StatefulShellRoute.indexedStack` and rarely disposes). It remains the highest-volume billed event; look there first if the invoice ever moves.
- **Revenue truth is Neon** (`subscriptions` table), never a sampled analytics tool.

### PostHog allow-list — FOUR events (trimmed 2026-07-29)
`feed_session_ended` · `wallpaper_applied` · `apply_blocked_premium` · `subscription_active`

Was eleven. The filter is not "is it interesting" but **"can nothing cheaper answer it"** — GA4 takes
every event at 100% for free, and Neon is authoritative for users, trials, subscriptions and
referrals. What survives is the behavioural sequence Neon cannot reconstruct: browsed → got value →
hit the paywall → paid. Pinned as an exact set by `test/core/analytics_gating_test.dart`, so adding a
fifth is a deliberate act, not a drive-by. Default-**deny**: a new `track()` call site costs nothing
in PostHog until it is added to `postHogAllowedEvents` in `analytics_provider.dart` — and GA4 still
gets it at 100% either way.

★ events carry `plan`, `order_id` (PhonePe merchant order id) and `value` (INR from
`app_config.prices.monthly`) for ROAS and dedupe.

## Property convention

Wallpaper events carry **`wallpaper_id` + `category`**; ringtone events carry **`ringtone_id` + `category`**. `category` is Arul's browse axis (amman·ayyappan·murugan·perumal·sivan·temples), so "which collections convert" is answerable off these events alone.

Static-vs-live rides along as **`type`** (`kind.name` → `image` / `live`), spelled identically on `wallpaper_engaged`, `wallpaper_apply_attempt`, `wallpaper_applied` and `wallpaper_shared` so the whole funnel is joinable on it. It is a rendering hint, never a browse axis (CLAUDE.md §5b) — do not group by it the way `category` is grouped.

## Events (keep in sync with `track()` call sites)

| Event | Properties | PostHog | Meta | GA4 standard |
|-------|------------|:---:|------|--------------|
| login_success / login_failed | provider, error, kind | | fb_mobile_complete_registration (success) | ★ login (success) |
| trial_started | plan, order_id, value | | ★ StartTrial | ★ purchase |
| subscription_active | plan, order_id, value | ✓ | ★ Subscribe | ★ purchase |
| feed_session_ended | cards_engaged, cards_engaged_live, cards_engaged_static, max_depth, seconds | ✓ | | |
| wallpaper_engaged | wallpaper_id, category, type | | | |
| wallpaper_apply_attempt | wallpaper_id, category, type, target | | | |
| wallpaper_applied | wallpaper_id, category, type, target, **confirmed** | ✓ | | |
| wallpaper_shared | wallpaper_id, type, category, result | | | |
| apply_blocked_premium | wallpaper_id, category | ✓ | | |
| share_blocked_premium | wallpaper_id, category | | | |
| ringtone_preview · ringtone_set_attempt ‡ | ringtone_id, category | | | |
| ringtone_set ‡ | ringtone_id, category | | | |
| ringtone_set_blocked_premium ‡ | — | | | |
| referral_shared | — | | | |
| share_watermark_failed | wallpaper_id, type, reason | | | |
| profile_name_updated · support_email_opened | has_user | | | |
| account_delete_{confirmed,failed} · account_deleted | error | | | |

Blank PostHog column = GA4-only (still captured at 100%, just not billed). Screen views: PostHog autocapture is OFF **and** `screen()` is dropped by `AllowlistedAnalyticsService`; GA4 auto `screen_view` covers screens.

**‡ = zero volume in v1.** The ringtones tab is parked (no audio published — `known-issues.md`), so nothing can reach the code that emits these. The wiring is intact and unchanged; read a v1 dashboard showing zero as "unreachable", not "broken", and don't delete the definitions.

### `wallpaper_applied.confirmed` — read this before quoting an apply rate

Arul has three apply paths and only two are observable:

| Path | `confirmed` | Why |
|---|:---:|---|
| static apply | `true` | native call returns or throws |
| live, our engine already active (in-place swap) | `true` | same — no chooser involved |
| live, OS chooser opens | `false` | the user makes the final "Set wallpaper" tap in an activity we cannot see |

The event fires on all three. Suppressing the chooser case would silently under-count the commonest live path and make the funnel non-comparable with Pakiza (which fires on chooser-open too). Filter `confirmed = true` for a strict completion count; **never quote the unfiltered number as a completion rate.**

### Where blocked-premium events come from

`{apply,share}_blocked_premium` fire from the feed's gate and from `ensurePremium()` (`entitlement_provider.dart`) with the `PremiumGateAction.source` name — the same string used as `/premium?source=`. `ringtone_set_blocked_premium` fires from `ensurePremium(source: 'ringtone_set')` **and** from the ringtones screen's error handler when the *server* gate refuses a set (a lapsed subscription with a stale client snapshot). Both paths are intended; one session can emit it twice, so read it as "block encountered", not "distinct blocks". `/premium`'s own `source` query param is display-only and tracks nothing — tracking happens at the gate.

## Deltas vs Pakiza

- **Gated-action keys are `apply` / `share`**, not Pakiza's `wallpaper_apply` / `wallpaper_share` — the `PremiumGateAction` enum that names the gate also supplies the `?source=` param, so the shorter name is load-bearing in the route.
- **`category` replaces Pakiza's `type`** as the second property on wallpaper/ringtone events. Do not unify — every saved dashboard in both projects is built on its own app's key.
- **`wallpaper_applied` carries `confirmed`** (above). Pakiza cannot distinguish the in-place live swap, so it has no equivalent.
- **Absent because the feature is absent:** Pakiza's All/New feed tab events (Arul filters by category — CLAUDE.md §5b), its Islamic-content and notification events, and per-tag page events (Arul has categories, not tags).
- **No upload events** in either app. If Arul instruments upload, keep it GA4-only unless a product decision rides on it.
