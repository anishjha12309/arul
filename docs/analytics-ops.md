# Analytics Ops — consoles, DebugView, Google Ads

Where to watch events land and how the ad-conversion wiring is set up. Event names, properties and
the PostHog allow-list live in [analytics-events.md](analytics-events.md).

## Watch events live

```bash
adb shell setprop debug.firebase.analytics.app com.hsrapps.arul   # on
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

1. Firebase console → Integrations → Google Ads → link `arul-502411`.
2. GA4 Admin → Events → mark `purchase` (optionally `login`) as a conversion.
3. Google Ads → Goals → Conversions → import the GA4 `purchase` conversion.

★ events are what feed this: `trial_started` and `subscription_active` both emit GA4 standard
`purchase`, deduped on `order_id`. `login_success` emits standard `login`.

## Before launch

The privacy policy (`https://hsrutility.com/privacy/` — SHARED with Pakiza, so a change there
lands in both apps) must disclose Meta, Google/Firebase and advertiser-ID collection.
