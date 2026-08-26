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
adb logcat -s FA-SVC:V FA:V     # FA:V only on debug/profile — release R8-strips the in-app tag
```
A successful upload logs the batch and a `204`.

## Google Ads

Conversions live in the SHARED Ads account `750-756-8746`, which also carries Pakiza's — a campaign
must pick its own app's conversion action. Arul imports BOTH GA4 conversions: **`trial_started`**
(Primary — what App-campaign bidding targets) and **`purchase`** (Secondary — observe-only, so it
never enters the Conversions column or bidding). **`purchase` is reported from BOTH sides, split by settle location** — never add a
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

Linkage + attribution traps — why an App campaign has no conversion goals, why Ads legitimately shows
zero while GA4 holds the events, and which console lies how:
[google-ads.md](google-ads.md) — read before diagnosing a missing conversion.

## Meta Events Manager

Dataset `4466425047008179`, linked to app `1818877069101534` (one app per dataset; created 2026-08-24
under the **HSR Co portfolio** scope — the ad-account scope had hit its creation limit, which reads
as a greyed-out "Create new", not an error). Linking is metadata: it changes nothing the SDK sends.
The EU-only "religious or spiritual beliefs" diagnostic is Meta's special-category handling of a
devotional app and applies to European users only — it does not touch IN campaigns or CAPI events.

Three ways the numbers legitimately disagree with PostHog/Neon — check these BEFORE suspecting the
pipe (a full day of diagnosis on 2026-08-24 ended in none of the code being wrong):
- **Meta only sees builds ≥ `1.0.0+38`.** `META_APP_ID` changed 2026-08-19 21:11 IST; every earlier
  build reports to the previous app id and never reaches this dataset. Compare on the same build set
  — PostHog `$app_build` splits it — not on totals. Parity so measured: 21–22 Aug at 94–100%.
- **A developer account under an integrity check (OTP/email/captcha) blacked out SDK receipt across
  EVERY event** — zero for 26 h (23 Aug ~07:30 → 24 Aug 08:30 IST), then 3 of 25 trials until the
  17:17 fix, then 4 of 4 — and the window did NOT backfill afterwards (measured from Meta's hourly
  CSV export against PostHog on the same UTC hour grid; no doc covers this path). For
  POLICY blocks Meta states it outright — Business Help 851247612299604: events during a block
  "aren't available for use in Meta advertising or measurement, even if … later unblocked". Either
  way: don't chase it. The SDK caches and flushes on 100 events / 15 s / foregrounding, so late
  bursts after recovery are backlog carrying original log times, not new traffic.
- **Ads Manager columns count ad-attributed conversions inside the attribution window** — Events
  Manager counts everyone. "—" with a populated dataset is arithmetic (google-ads.md, same trap).

CAPI `Subscribe` is the Worker's (`workers/src/lib/meta.ts`, secrets `META_DATASET_ID` +
`META_CAPI_ACCESS_TOKEN`); it rides neither the SDK nor the developer account, so it survives both
outages above. It is sent as **`action_source: system_generated`** (Meta's definition: an auto-pay
renewal) — NOT `app`: an app event needs an `extinfo` with a real OS version, Meta bounces a blank
one (error_subcode 2804043, cost the first three real conversions on 2026-08-25), and the server
has no device to read one from. Sending true app events later needs the client to upload device
info next to `meta_anon_id`. Shape-check without polluting the dataset: `node workers/tools/meta-capi-validate.mjs
<test_event_code>` (Test events tab only). The Copy button there can silently copy nothing — read the
code off the screen.

**EMQ levers are bounded by Play's Data safety form, not by Meta.** Events Manager offers IP (+35%),
user agent (+35%) and IP-derived city/region/postcode (+15% each) for `Subscribe`; Google's policy
says an IP "used to determine location" must be declared and ad-measurement use is never
"ephemeral", so each of those is a new declaration + a privacy-policy edit before it may ship.
Hashed first/last name from Google `display_name` is the ONE key that adds no data type and no
recipient (email already goes to the same event) and is the only one sent (owner, 2026-08-25).
Normalisation copies Meta's capi-param-builder verbatim (`normalizeMetaName`); do not add the
library itself — it needs Node `net`/`Buffer`, and its appendix suffix is telemetry, not matching.

The privacy policy (`https://hsrutility.com/arul/privacy-policy/` — Arul's own since 2026-08-20; it
is no longer shared with Pakiza, so a change here lands in this app alone) must disclose Meta,
Google/Firebase and advertiser-ID collection.
