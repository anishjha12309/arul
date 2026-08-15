# Analytics Ops — DebugView, logcat, Ads

Where to watch events land. Event semantics: [analytics-events.md](analytics-events.md).

## Watch events live

```bash
adb shell setprop debug.firebase.analytics.app com.hsrutility.arul   # on
adb shell setprop debug.firebase.analytics.app .none.                # off (the trailing dot is the sentinel)
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
must pick its own app's conversion action. Arul imports BOTH GA4 conversions: **`purchase`**
(Primary — the ROAS signal, real money) and **`trial_started`** (the volume signal Smart Bidding
should target). **`purchase` is reported from BOTH sides, split by settle location** — never add a
third reporter: the client logs it only for the app-open flow (repeat subscriber, ₹199 at setup),
and the Worker reports app-closed settles (trial→paid, renewals) via the GA4 Measurement Protocol
(`workers/src/lib/ga4.ts`, keyed on the `app_instance_id` uploaded at login/initiate; both sides
carry a PhonePe order id as `transaction_id`, but **that dedupes nothing** — GA4's `transaction_id`
dedupe is web-stream only and this is an app stream, and the two sides send different ids anyway. The
split plus the Worker's KV mark is the whole protection). Server reporting is silently OFF until the
`GA4_API_SECRET` worker secret is set (GA4 Admin → Data streams → Android stream → Measurement
Protocol API secrets); `/mp/collect` answers 2xx even for payloads it DROPS. `node
workers/tools/ga4-mp-validate.mjs <app_instance_id>` checks payload SHAPE only — it reads the local
`.dev.vars`, and GA4's debug endpoint validates neither `api_secret` nor `firebase_app_id`, so it
cannot prove the deployed wiring. Users on builds that
never uploaded an id stay unreported — **Neon remains revenue truth** (CLAUDE.md §Analytics).

The privacy policy (`https://hsrutility.com/privacy/` — SHARED with Pakiza, a change lands in both
apps) must disclose Meta, Google/Firebase and advertiser-ID collection.
