# Analytics Events

Never call SDKs from widgets — always `AnalyticsService`. `CompositeAnalyticsService` fans out to:
- **PostHog** — a ~5% **user panel**, allow-listed events only. Two gates: `AnalyticsCohort` (is this install in the panel?) and `AllowlistedAnalyticsService` (is this event on the list?). Active when `POSTHOG_KEY` is real **and** the install is in the cohort.
- **GA4** (`firebase_analytics`) — **every event at 100%, from every install** (raw name) + ★ events also emit GA4 *standard* `login`/`purchase` = Google Ads conversion source. Active when `AppConfig.firebaseEnabled` (real builds with `google-services.json`; `flutter test` skips). Auto-collects first_open/session_start/screen_view. **This is the complete, unsampled record** — anything PostHog drops is still measurable here for free.
- **Meta App Events** — ONLY ★ events (clean conversion signal); installs/launches auto-logged natively. Active when `AppConfig.metaEnabled` (real `META_APP_ID` + `META_CLIENT_TOKEN` dart-defines).

Mirrored in Pakiza (`c:\Anish\Pakiza\docs\analytics-events.md`) — the MECHANISM is identical and must stay in sync. The event list and properties differ only where the apps differ; see [Deltas vs Pakiza](#deltas-vs-pakiza).

## PostHog cost model (why it's gated twice)

PostHog bills per event; the free tier is 1M events/month. Divided across a large user base that is well under **one event per user per month**, so no amount of trimming the event *list* fits inside it — `login_success` alone, once per user, would blow it. The only lever that works is **not sending for most users**.

- **`AnalyticsCohort` (`_rate = 0.05`)** — a persisted per-install draw decides panel membership. Gates `Posthog().setup()` itself in `main.dart`, so a non-panel install does zero PostHog init/network/battery work. User-level sampling keeps each panel member's history *complete*, so funnels/retention/paths are **exact** within the panel; scale absolute counts by 1/rate. (Event-level sampling silently corrupts funnels: a 10% numerator over a 100% denominator is meaningless.) The stored value is the **draw, not a boolean**, so widening the rate later only ever *adds* installs and never breaks a retention curve.
- **`captureApplicationLifecycleEvents = false`** — the SDK's `Application Opened`/`Backgrounded`/`Installed`/`Updated` fire natively, never pass through `AnalyticsService`, and so can't be filtered downstream. They are the single largest source of billed volume. GA4's `first_open`/`session_start` already give DAU + retention across 100% of installs for free. `sessionReplay` and `surveys` are off for the same reason, and no `PosthogObserver`/`PostHogWidget` is installed, so there is no element autocapture either.
- **`Posthog().setup()` is not awaited** — native init + the SDK's first network work must not sit on the critical path to the first frame. Nothing captures before the first user action anyway.
- **`feed_session_ended`** — ONE summary per feed session (`cards_engaged`, `cards_engaged_live/static`, `max_depth`, `seconds`) instead of one `wallpaper_engaged` per card. PostHog bills per event, **not per property**. Flushed on app-background (the feed lives in a `StatefulShellRoute.indexedStack` and rarely disposes).
- **Revenue truth is Neon** (`subscriptions` table), never a sampled analytics tool.

### PostHog allow-list (the only billed events) — FOUR, trimmed 2026-07-29
`feed_session_ended` · `wallpaper_applied` · `apply_blocked_premium` · `subscription_active`

Was eleven. Cut to four on an explicit cost decision. The filter is not "is it interesting" but
**"can nothing cheaper answer it"** — GA4 takes every event at 100% for free, and Neon is
authoritative for users, trials, subscriptions and referrals (revenue truth is never PostHog). What
survives is the behavioural sequence Neon cannot reconstruct: browsed → got value → hit the paywall →
paid. Pinned as an exact set by `test/core/analytics_gating_test.dart`, so adding a fifth is a
deliberate act, not a drive-by.

**Dropped in the trim** (each is still in GA4 at 100%, and most are in Neon authoritatively):
`login_success`, `trial_started`, `referral_shared` (Neon owns users/trials/referrals),
`wallpaper_shared`, `ringtone_set` (secondary value moments), `share_blocked_premium`,
`ringtone_set_blocked_premium` (the apply gate carries the volume; the funnel shape is identical).

Honest sizing: this is a **modest** saving, not the main protection. The two levers that actually
bound the bill are already in place and matter far more — the ~5% cohort gate, and rolling the feed
up to one `feed_session_ended` per session instead of one event per card. `feed_session_ended`
remains the highest-volume billed event; look there first if the invoice ever moves.

Default-**deny**: a new `track()` call site costs nothing in PostHog until it's added to
`postHogAllowedEvents` in `analytics_provider.dart` — and GA4 still gets it at 100% either way.
Also deliberately absent: `wallpaper_engaged`, `wallpaper_apply_attempt`, `ringtone_preview`,
`ringtone_set_attempt`, `login_failed`, `share_watermark_failed`, `profile_name_updated`,
`support_email_opened`, `account_delete_confirmed`, `account_delete_failed`, `account_deleted`, and
all screen views.

★ events carry `plan`, `order_id` (PhonePe merchant order id), `value` (INR from `app_config.prices.monthly`) for ROAS + dedupe. **Privacy policy must disclose Meta + Google/Firebase + advertiser-ID before launch.**

## Property convention

Wallpaper events carry **`wallpaper_id` + `category`**; ringtone events carry **`ringtone_id` + `category`**. `category` is Arul's browse axis (amman·ayyappan·murugan·perumal·sivan·temples), so "which collections convert" is answerable off these events alone.

Static-vs-live rides along as **`type`** (`kind.name` → `image` / `live`), spelled identically on `wallpaper_engaged`, `wallpaper_apply_attempt`, `wallpaper_applied` and `wallpaper_shared` so the whole funnel is joinable on it. It is a rendering hint, never a browse axis (CLAUDE.md §5b) — do not group by it the way `category` is grouped.

## Events (current — keep in sync with `track()` call sites)

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
| ringtone_preview · ringtone_set_attempt | ringtone_id, category | | | |
| ringtone_set | ringtone_id, category | | | |
| ringtone_set_blocked_premium | — | | | |
| referral_shared | — | | | |
| share_watermark_failed | wallpaper_id, type, reason | | | |
| profile_name_updated · support_email_opened | has_user | | | |
| account_delete_{confirmed,failed} · account_deleted | error | | | |

Blank PostHog column = GA4-only (still captured at 100%, just not billed). Screen views: PostHog autocapture is OFF **and** `screen()` is dropped by `AllowlistedAnalyticsService`; GA4 auto `screen_view` covers screens.

### `wallpaper_applied.confirmed` — read this before quoting an apply rate

Arul has three apply paths and only two are observable:

| Path | `confirmed` | Why |
|---|:---:|---|
| static apply | `true` | native call returns or throws |
| live, our engine already active (in-place swap) | `true` | same — no chooser involved |
| live, OS chooser opens | `false` | the user makes the final "Set wallpaper" tap in an activity we cannot see |

The event fires on all three. Suppressing the chooser case would silently under-count the commonest live path and make the funnel non-comparable with Pakiza (which fires on chooser-open too). Filter `confirmed = true` for a strict completion count; **never quote the unfiltered number as a completion rate.**

### Where blocked-premium events come from

`{apply,share}_blocked_premium` fire from the feed's gate and from `ensurePremium()` (`entitlement_provider.dart`) with the `PremiumGateAction.source` name — the same string used as `/premium?source=`. `ringtone_set_blocked_premium` fires from `ensurePremium(source: 'ringtone_set')` **and** from the ringtones screen's error handler when the *server* gate refuses a set (a lapsed subscription with a stale client snapshot). Both paths are intended; a single user session can therefore emit it twice, so treat it as "block encountered", not "distinct blocks". `/premium`'s own `source` query param is display-only and tracks nothing — tracking happens at the gate.

## Deltas vs Pakiza

Same mechanism, different catalogue where the apps differ:

- **Gated-action keys are `apply` / `share`**, not Pakiza's `wallpaper_apply` / `wallpaper_share` — the `PremiumGateAction` enum that names the gate also supplies the `?source=` param, so the shorter name is load-bearing in the route.
- **`category` replaces Pakiza's `type`** as the second property on wallpaper/ringtone events. Category is Arul's browse axis; Pakiza has none. Do not unify — every saved dashboard in both projects is built on its own app's key.
- **`wallpaper_applied` carries `confirmed`** (above). Pakiza cannot distinguish the in-place live swap, so it has no equivalent.
- **Not ported, feature absent in Arul:** Pakiza's All/New feed tabs (Arul filters by category only — CLAUDE.md §5b forbids the New tab), so no tab/filter events; Pakiza's Islamic-content and notification events; per-tag page events (Arul has categories, not tags).
- **No upload events** in either app — the upload feature is instrumented in neither, so there is nothing to port. If Arul instruments it, keep it GA4-only unless a product decision rides on it.

## Google Ads conversion setup (console, no code)
1. Firebase console → Integrations → Google Ads → link `arul-502411`.
2. GA4 Admin → Events → mark `purchase` (optionally `login`) as conversion.
3. Google Ads → Goals → Conversions → import the GA4 `purchase` conversion.

## Where to see events
- **DebugView** (live): `adb shell setprop debug.firebase.analytics.app com.hsrapps.arul` → Firebase → Analytics → DebugView (off: `...app .none`).
- **Realtime:** Firebase/GA4 → Analytics → Realtime. **Reports:** GA4 → Reports → Engagement → Events (24–48h).
- **Meta:** Events Manager → app → Test Events / Overview. **PostHog:** project → Activity.
- **Verifying the GA4 upload path on a release build** needs `adb shell setprop log.tag.FA-SVC VERBOSE` (hyphen, then restart GMS) — see Pakiza's ad-engine verification notes.
