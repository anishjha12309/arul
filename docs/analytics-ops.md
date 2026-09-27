# Analytics ops — consoles, logcat and reading the data

Where to watch events land and how not to misread them. Event semantics and the one-source conversion
rule: [analytics-events.md](analytics-events.md) · Ads linkage and attribution:
[google-ads.md](google-ads.md) — read it before diagnosing a missing conversion.

## Watch events live

```bash
adb shell setprop debug.firebase.analytics.app com.hsrutility.arul   # on
adb shell setprop debug.firebase.analytics.app .none.                # off (the trailing dot is the sentinel)
```

Then Firebase → Analytics → **DebugView**. The flag is per device and SURVIVES reinstalls — turn it off,
or that device stays out of the normal reports indefinitely. **Release builds have no DebugView**; prove
the upload path from logcat instead:

```bash
adb shell setprop log.tag.FA-SVC VERBOSE   # note the HYPHEN, then restart Google Play services
adb logcat -s FA-SVC:V FA:V                # FA:V only on debug/profile — R8 strips the in-app tag
```

A successful upload logs the batch and a `204`; `FA-SVC Logging event` lines show each event's params.

## GA4 blind spots

- **A custom parameter is invisible to every report and the Data API until registered as a custom
  dimension** (Admin → Data display → Custom definitions; event-scoped cap 50). Asking for one returns
  `Field customEvent:<name> is not a valid dimension`. "GA4 is the complete record" holds for EVENTS,
  not parameters — check the registered list before promising a GA4 answer.
- **GA4 cannot segment by build.** `appVersion` is `versionName`, and the build lives in the `+N`
  suffix, so every install reports the same name. **PostHog's `$app_build` is the build-aware surface**;
  Crashlytics reads `versionCode`.

## Only a PLAY install reports to PostHog

**No sideloaded build — release APK or debug — may reach PostHog** (owner's rule): a release APK on a
developer's phone is the same binary as a store install, so without a gate every device pass writes
itself into the funnel. `PlayInstall` (`core/config/build_info.dart`) asks the native installer check
FLAG_SECURE already rides, ONCE per process in `main()` before `Posthog().setup()`, so the first event is
already gated.

- **It fails toward PLAY** — a platform error or an unresolvable installer answers "Play"; dropping a
  real user costs more than admitting a developer. A MISSING channel (`flutter test`, host builds)
  reports nothing.
- **GA4, Meta and Crashlytics are NOT gated** — GA4 is the complete record and the Ads conversion
  source, and a crash from a test build is wanted. Changing that is the owner's call.
- `--dart-define=DIAG=true` logs the decision at startup.
- **An on-device walkthrough therefore proves nothing about the PostHog funnel** — check GA4. To test
  the PostHog sink itself, install with Play named as installer (`adb push` then
  `adb shell pm install -i com.android.vending /data/local/tmp/<apk>`) on a phone inside the project's
  test-account filter, never on top of a Play copy (the debug key cannot update it — uninstall first,
  reinstall from Play after).
- **PostHog event order is per batch, not per capture** — `timestamp` is corrected by each batch's clock
  skew, so two events from one launch can swap by hundreds of ms; `created_at` keeps the phone's order.

## Meta Events Manager

One app per dataset; linking is metadata and changes nothing the SDK sends. The EU-only "religious or
spiritual beliefs" diagnostic is Meta's special-category handling of a devotional app and never touches
IN campaigns. Three ways the numbers legitimately disagree with PostHog or Neon — check these BEFORE
suspecting the pipe (a full day of diagnosis once found no code wrong):

- **Meta sees only builds that carry the current `META_APP_ID`.** Compare on the same build set
  (PostHog's `$app_build`), never on totals.
- **A developer account under an integrity check (OTP/email/captcha) blacks out SDK receipt for EVERY
  event, and the window never backfills** — for policy blocks Meta says so outright. The SDK flushes on
  100 events / 15 s / foregrounding, so a burst after recovery is backlog carrying original log times.
- **Ads Manager counts ad-attributed conversions inside the attribution window**; Events Manager counts
  everyone. "—" beside a populated dataset is arithmetic, not a fault.

**CAPI `Subscribe` must not come back** — not in the Worker, `MetaAnalyticsService` or a custom
conversion ([analytics-events.md](analytics-events.md)). The Meta-specific half of the reason: the
server could only send `action_source: system_generated` (`app` needs an `extinfo` with a real OS
version), which Meta files under WEBSITE events, so one conversion arrived from two source types.

The hashed first/last name from the Google `display_name` is the ONE user key sent (owner): it adds no
data type or recipient, since email already goes to the same event. Normalisation copies Meta's
capi-param-builder verbatim — never add the library, which needs Node `net`/`Buffer` and whose appendix
suffix is telemetry. The privacy policy must disclose Meta, Google/Firebase and advertiser-ID collection.

## Reading the data — rules that prevent wrong conclusions

- `wallpaper_applied.confirmed` is `true` on a static apply **and on the static fallback** (which also
  carries `fallback: true`, present ONLY there). Every other live apply fires `confirmed=false` on
  chooser-open, because the OS "Set" tap is unobservable. Filter `confirmed=true` for a strict
  completion count; **never quote the unfiltered number as a completion rate.**
- **`wallpaper_apply_live_fallback` is an over-fire tripwire.** Its rate against
  `wallpaper_apply_attempt` with `type=live` must sit near zero on mainstream hardware; a rise means
  capable devices are being routed to a still image. `reason` is `featureMissing`,
  `chooserUnavailable` or `unknown`.
- **`wallpaper_apply_failed` is only ever a SUBSET of `wallpaper_apply_attempt`** — a signed-url refusal
  or a dead connection mid-download is deliberately absent. A premium refusal is
  `apply_blocked_premium`. `code` is the native `PlatformException.code`, else `network`/`unknown`.
- `*_blocked_premium` fires from the client gate AND the server-refusal handler, so one session can emit
  it twice: read "block encountered", never "distinct blocks".
- `link_attributed=false` means the outgoing link carried no referral code — that install can never be
  credited to the sender. `result` is always `unavailable` on the `whatsapp` channel: the target app
  never reports back.
- Sign-in outcome buckets: [auth.md](auth.md) §Reading the failure buckets.
- Server-event delivery proof without console access: the Worker writes `ph:<event>:<txn>` to KV
  **only** on an accepted send, stamped with the row's RETURNED `updated_at`, not `now()` — PostHog
  dedupes on `[timestamp, distinct_id, event, uuid]`, and a wall-clock stamp made the deterministic
  `uuid` inert.
