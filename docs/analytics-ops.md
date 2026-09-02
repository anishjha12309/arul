# Analytics Ops — DebugView, logcat, consoles

Where to watch events land. Event semantics and the one-source conversion rule:
[analytics-events.md](analytics-events.md). Ads linkage and attribution traps:
[google-ads.md](google-ads.md) — read that before diagnosing a missing conversion.

## Watch events live

```bash
adb shell setprop debug.firebase.analytics.app com.hsrutility.arul   # on
adb shell setprop debug.firebase.analytics.app .none.                # off (the trailing dot is the sentinel)
```
Then Firebase → Analytics → **DebugView**. The flag is per-device and SURVIVES reinstalls — turn it
off when done, or that device's data stays out of the normal reports indefinitely.

**Release builds have no DebugView.** Prove the GA4 upload path from logcat instead:

```bash
adb shell setprop log.tag.FA-SVC VERBOSE   # note the HYPHEN, then restart Google Play services
adb logcat -s FA-SVC:V FA:V     # FA:V only on debug/profile — release R8-strips the in-app tag
```
A successful upload logs the batch and a `204`.

## Custom parameters are NOT queryable until registered

**Every custom parameter the app sends is invisible to all GA4 reports and to the Data API until it
is registered as a custom dimension.** Asking for an unregistered one returns
`Field customEvent:<name> is not a valid dimension`. "GA4 is the complete, unsampled record" holds at
the EVENT level, not the PARAMETER level.

Affected: `gis_code` · `ms_since_authenticate` · `description` · `error` · `reason` · `method` ·
`target_app` · `type` · `category` · `plan` · `late` · `surface`. So "which UPI app expires the
mandate" is not answerable off `method`/`target_app` until each is registered in **Admin → Data
display → Custom definitions** (event-scoped, cap 50). Console only, no code.

**GA4 cannot segment by build either.** `appVersion` is Firebase's `versionName`, and `pubspec.yaml`
carries the build in the `+N` suffix, so every install reports the same `versionName` and "is this
fixed in the new build?" is unanswerable there. **PostHog's `$app_build` is the build-aware surface
for events**; Crashlytics reads `versionCode` for crashes. Bump `versionName` per release, or send
the build as a user property, before trusting a build-wise GA4 read.

## Meta Events Manager

One app per dataset. Linking is metadata: it changes nothing the SDK sends. The EU-only "religious or
spiritual beliefs" diagnostic is Meta's special-category handling of a devotional app and applies to
European users only — it does not touch IN campaigns.

Three ways the numbers legitimately disagree with PostHog or Neon — check these BEFORE suspecting the
pipe. A full day of diagnosis once ended in none of the code being wrong.

- **Meta only sees builds from the one where `META_APP_ID` changed onward.** Every earlier build
  reports to the previous app id and never reaches this dataset. Compare on the same build set —
  PostHog's `$app_build` splits it — never on totals.
- **A developer account under an integrity check (OTP/email/captcha) blacks out SDK receipt across
  EVERY event**, for as long as the check stands, **and the window does NOT backfill afterwards**.
  For POLICY blocks Meta states it outright: events during a block "aren't available for use in Meta
  advertising or measurement, even if … later unblocked". Either way, don't chase it. The SDK caches
  and flushes on 100 events / 15 s / foregrounding, so late bursts after recovery are backlog
  carrying original log times, not new traffic.
- **Ads Manager columns count ad-attributed conversions inside the attribution window** — Events
  Manager counts everyone. "—" beside a populated dataset is arithmetic, not a fault.

**CAPI `Subscribe` was removed and must not come back** — not in the Worker, not in
`MetaAnalyticsService`, not as a custom conversion. The reason is in
[analytics-events.md](analytics-events.md) §ONE conversion action; the Meta-specific half is that the
server could only send **`action_source: system_generated`** (`app` needs an `extinfo` with a real OS
version, and Meta bounces a blank one), which Meta files under WEBSITE events. So one conversion
event arrived from two source types and campaign attribution desynchronised while the dataset's raw
counts stayed correct.

Hashed first/last name from the Google `display_name` is the ONE user key that adds no data type and
no recipient — email already goes to the same event — and is the only one sent (owner's call).
Normalisation copies Meta's capi-param-builder verbatim; do not add the library itself, which needs
Node `net`/`Buffer` and whose appendix suffix is telemetry, not matching.

The privacy policy must disclose Meta, Google/Firebase and advertiser-ID collection. Arul's policy
pages are its own and are not shared with Pakiza, so a change there lands in this app alone
(CLAUDE.md §1).

## Reading the data — rules that prevent wrong conclusions

Event definitions are in [analytics-events.md](analytics-events.md); these are the traps in
interpreting what they record.

- `wallpaper_applied.confirmed` is `true` on a static apply **and on the one live apply that never
  reaches a chooser**, the static fallback, which carries `fallback: true` beside it (present ONLY
  there). Every other live apply goes through the OS chooser, whose final "Set" tap is unobservable —
  those fire `confirmed=false` on chooser-open. Filter `confirmed=true` for a strict completion
  count; **never quote the unfiltered number as a completion rate.**
- **`wallpaper_apply_live_fallback` is an over-fire tripwire, not a feature metric.** Its rate against
  `wallpaper_apply_attempt` where `type=live` is the whole question: the fallback is for devices where
  live apply is impossible, so on mainstream hardware it must sit near zero. `reason` is
  `featureMissing` or `chooserUnavailable`, with `unknown` when the native side sends none.
- **`wallpaper_apply_failed` is only ever a SUBSET of `wallpaper_apply_attempt`** — it fires from the
  notifier's catch, but only once the attempt event has, so a signed-url refusal or a dead connection
  mid-download is deliberately absent (counting one would put the numerator outside its denominator).
  A premium refusal is `apply_blocked_premium`, never this. `code` is the native
  `PlatformException.code`, else `network`/`unknown`.
- `link_attributed=false` means the outgoing link carried no referral code. A WALLPAPER share still
  ships the App Link without `?ref=` (the Worker's Play redirect turns a code into `referrer=`); a
  REFERRAL share falls back to a plain store listing. Either way the install can never be credited to
  the sender, so a `source` that is always unattributed has its referral warm-up in the wrong place.
- `result` is always `unavailable` on the `whatsapp` channel — the target app owns the outcome and
  never reports back. Not a failure. `channel` says whether skipping the chooser pays off.
- `*_blocked_premium` fires from the client gate AND from the server-refusal handler, on all three
  gated verbs, so one session can emit it twice. Read as "block encountered", never "distinct
  blocks". Tracking is at the gate; `/premium?source=` is display-only.
- Delivery proof for the server events without console access: the Worker writes
  `ph:<event>:<txn>` to KV **only** on an accepted send, stamped with the row's RETURNED
  `updated_at`, not `now()` — PostHog dedupes on `[timestamp, distinct_id, event, uuid]`, so a
  wall-clock stamp had made the deterministic `uuid` inert.
