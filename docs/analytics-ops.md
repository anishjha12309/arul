# Analytics Ops — consoles, DebugView, Google Ads

Where to watch events land and how the ad-conversion wiring is set up. Event names, properties and
the PostHog allow-list live in [analytics-events.md](analytics-events.md).

## Watch events live

```bash
adb shell setprop debug.firebase.analytics.app com.hsrutility.arul   # on
adb shell setprop debug.firebase.analytics.app .none              # off
```
Then Firebase console → Analytics → **DebugView**. Debug mode is per-device and survives reinstalls,
so turn it off when done or that device's data stays out of the normal reports.

| Surface | Where | Latency |
| --- | --- | --- |
| GA4 realtime | Firebase/GA4 → Analytics → Realtime | seconds |
| GA4 reports | GA4 → Reports → Engagement → Events | 24–48 h |
| Meta | Events Manager → app → Test Events / Overview | minutes |
| PostHog | project → Activity | seconds |

**On a release build, DebugView is not available.** Prove the GA4 upload path from logcat instead:

```bash
adb shell setprop log.tag.FA-SVC VERBOSE      # note the HYPHEN, then restart Google Play services
adb logcat -s FA-SVC:V FA:V
```
A successful upload logs the batch and a `204`. Pakiza's ad-engine verification notes carry the full
recipe and the reasons blind UI-driving fails under `FLAG_SECURE`.

## Google Ads conversions (console only, no code)

Ads account `750-756-8746`. Nav moved in 2026: it is **Tools → Data manager**, not the retired
"Linked accounts", and Firebase can no longer create the link (Analytics owns it).

1. Ads → **Tools → Data manager → + Connect Product → Google Analytics (GA4) & Firebase** → link
   the GA4 property of `arul-prod-db4f8`. Keep **Personalized Advertising ON**; auto-tagging ON.
2. GA4 → **Admin → Data display → Events → Key events** → mark the events you want. Only key
   events are importable, and one must have **fired at least once** to appear. Allow **24–48h**.
3. Ads → **Goals → Summary → + Create conversion action → Conversions on an app → Set up →
   Google Analytics** → pick the event. Then **Goals tab → Edit goal**: set **Primary** AND
   **account-default** (both are required for default bidding).

**Which event to import — they are now separate on purpose:**
- **`trial_started`** — the volume signal. Fires client-side the moment a mandate is set up, so it
  is the practical optimisation target for Smart Bidding. Carries `value`, but it is NOT revenue.
- **`purchase`** (from `subscription_active` only) — the ROAS signal, real money.

`purchase` is deliberately NOT emitted at trial start: a trial debits nothing, and mapping both
booked phantom revenue and counted one subscriber twice. `login_success` still emits standard
`login`.

⚠️ **`purchase` under-reports.** `subscription_active` only fires when the purchase flow itself
returns `active` (repeat subscriber, ₹199 upfront). A trial converting later happens server-side
with the app closed, so no client event exists. Until the Worker reports it via the GA4 Measurement
Protocol, bid on `trial_started` and treat **Neon as revenue truth** (CLAUDE.md §Analytics).

## Before launch

The privacy policy (`https://hsrutility.com/privacy/` — SHARED with Pakiza, so a change there
lands in both apps) must disclose Meta, Google/Firebase and advertiser-ID collection.
