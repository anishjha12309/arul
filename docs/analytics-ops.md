# Analytics Ops — DebugView, logcat, Ads

Where to watch events land. Event semantics: [analytics-events.md](analytics-events.md).

## Watch events live

```bash
adb shell setprop debug.firebase.analytics.app com.hsrutility.arul   # on
adb shell setprop debug.firebase.analytics.app .none                 # off
```
Then Firebase → Analytics → **DebugView**. The flag is per-device and SURVIVES reinstalls — turn it
off when done or that device's data stays out of the normal reports indefinitely.

**Release builds have no DebugView.** Prove the GA4 upload path from logcat instead:

```bash
adb shell setprop log.tag.FA-SVC VERBOSE   # note the HYPHEN, then restart Google Play services
adb logcat -s FA-SVC:V FA:V
```
A successful upload logs the batch and a `204`.

## Google Ads

Conversions live in the SHARED Ads account `750-756-8746`, which also carries Pakiza's — a campaign
must pick its own app's conversion action. Arul's GA4 **`purchase`** is imported as Primary; **bid on
`trial_started`** for volume, because `purchase` under-reports: `subscription_active` fires only when
the purchase flow itself returns `active` (repeat subscriber, ₹199 upfront), while a trial converting
later happens server-side with the app closed — no client event exists. Until the Worker reports that
via the GA4 Measurement Protocol, treat **Neon as revenue truth** (CLAUDE.md §Analytics).

The privacy policy (`https://hsrutility.com/privacy/` — SHARED with Pakiza, a change lands in both
apps) must disclose Meta, Google/Firebase and advertiser-ID collection.
