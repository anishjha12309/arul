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
must pick its own app's conversion action. Arul imports exactly ONE GA4 conversion: **`trial_started`**
(Primary — what App-campaign bidding targets).
**`purchase` was REMOVED entirely on 2026-08-26 (owner's call) and must stay out** — unmarked as a GA4
key event, absent from the Ads import, and emitted by neither the app nor the Worker. It used to be
reported from BOTH sides split by settle location (client = app-open ₹199 setup; Worker = app-closed
trial→paid/renewals via the Measurement Protocol, keyed on `app_instance_id`). That split stopped double
counting but gave ONE conversion action TWO data sources, which desynchronises attribution: GA4's raw
event counts stayed correct while the CAMPAIGN column ran ~a day behind and undercounted, because the
two sources reconcile on different schedules. `trial_started` is app-SDK sourced and in-session — one
source, no split. Trial→paid is ~84%, so bidding loses no signal; the accepted cost is that Ads has NO
revenue/ROAS signal. **Neon is revenue truth** (CLAUDE.md §Analytics).

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

**CAPI `Subscribe` was REMOVED on 2026-08-26 (owner's call) — do not re-add it**, not in the Worker, not
in `MetaAnalyticsService`, not as a custom conversion. The server could only send
**`action_source: system_generated`** — `app` needs an `extinfo` with a real OS version and Meta bounces
a blank one (error_subcode 2804043, cost the first three real conversions on 2026-08-25). Meta files
`system_generated` under WEBSITE events (the dataset offered only a Website tab and asked for better
`fbc` coverage, a web click param), so ONE conversion event arrived from TWO source types — app SDK for
the app-open ₹199 setup, web-shaped server events for trial→paid — and campaign attribution
desynchronised while the dataset's raw counts stayed correct. **StartTrial (`start_trial_mobile_app`) is
the only event campaigns optimise on**: app-SDK, in-session, one source. `workers/src/lib/meta.ts` now
holds only the anon-id validator; the `META_DATASET_ID`/`META_CAPI_ACCESS_TOKEN` secrets and
`meta-capi-validate.mjs` are gone. Accepted cost: no revenue/ROAS signal on Meta.
Hashed first/last name from Google `display_name` is the ONE key that adds no data type and no
recipient (email already goes to the same event) and is the only one sent (owner, 2026-08-25).
Normalisation copies Meta's capi-param-builder verbatim (`normalizeMetaName`); do not add the
library itself — it needs Node `net`/`Buffer`, and its appendix suffix is telemetry, not matching.

The privacy policy (`https://hsrutility.com/arul/privacy-policy/` — Arul's own since 2026-08-20; it
is no longer shared with Pakiza, so a change here lands in this app alone) must disclose Meta,
Google/Firebase and advertiser-ID collection.


## Custom parameters are NOT queryable until registered (2026-08-29)

**This property has ZERO registered custom dimensions** — every custom parameter the app sends is
invisible to all GA4 reports and to the Data API. Verified: asking for `customEvent:reason` returns
`Field customEvent:reason is not a valid dimension`. "GA4 is the complete, unsampled record" holds at
the EVENT level, not the PARAMETER level. Affected: `gis_code` · `ms_since_authenticate` · `reason` ·
`method` · `target_app` · `type` · `category` · `plan` · `late` — so "which UPI app expires the
mandate" is not answerable off `method`/`target_app` until each is registered in **Admin → Data
display → Custom definitions** (event-scoped, cap 50). Console only, no code.

**GA4 cannot segment by build either.** `appVersion` is Firebase's `versionName`; `pubspec.yaml` is
`1.0.0+<build>`, so every install reports `1.0.0` and "is this fixed in the new build?" is
unanswerable there. Crashlytics is the only build-aware surface (it reads `versionCode`). Bump
versionName per release, or send the build as a user property, before trusting a build-wise read.
