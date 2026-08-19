# Google Ads / Firebase / GA4 — linkage and attribution traps

Read before diagnosing "conversions aren't showing in Ads". Event semantics:
[analytics-events.md](analytics-events.md) · consoles + logcat: [analytics-ops.md](analytics-ops.md).

## Ads counts ONLY ad-attributed conversions

GA4 holding N key events does not mean Ads shows N — Ads records only the subset it can trace to an
ad click. **"Conversion has never received data" is usually TRUE, not a fault.** Before suspecting a
broken link, read the medium split: GA4 → Reports → Acquisition → **User acquisition** → the "Key
events" dropdown → pick the event → read the **cpc** row. Zero there means Ads is right and the
problem is traffic, not plumbing.

Paid for 2026-08-19: hours spent hunting a link fault that did not exist. GA4 held 30 `trial_started`
(5 from cpc) and 8 `purchase` (0 from cpc); Ads was reporting both correctly.

## App campaigns have NO conversion goals

`Settings → Goals → campaign-specific goal settings` exists for Search/Shopping/PMax/Demand Gen
**only**. Google Ads API: *"You can only set the `selective_optimization` field of Campaign on an App
campaign. For all other campaign types, use campaign goals."* The App-campaign control is
**Settings → Bidding → "In-app actions"**, then the specific action — that is `selective_optimization`.
Account-default goals therefore cannot hijack an App campaign's bidding.

**Optimising toward an in-app action needs ≥10 distinct users/day on it** (Google's own floor; below
that they instruct you to pick a commoner action). `trial_started` is not a signup — it is a UPI
Autopay mandate authorisation (₹2 PENNY_DROP, `maxAmount` ₹199, UPI PIN entry), so it is bottom-funnel
by construction and runs single digits/day. Keep it as a measured conversion; bid on something
upstream.

## `value` without `currency` is silently discarded

GA4 drops `value` unless `currency` rides on the SAME event — the event still records, with
`ga_error(_err)=19` / `ga_error_value(_ev)=currency` — and Ads then books the conversion action's
fallback (₹1, per its "if there's no value" setting). `_clean()` in `google_analytics_service.dart`
pairs INR with every surviving `value`; never add a valued event on a path that bypasses it.
`logPurchase` was never affected because it always passed currency explicitly — that asymmetry is the
fastest way to confirm the bug is back (raw event at ₹0, `purchase` at its real value).

## Consoles lie in specific ways

- **Firebase DebugView has no key-event flag** — it renders every event identically. Only **GA4's**
  DebugView marks key events (green flag / `firebase_conversion` param). Never judge key-event status
  from Firebase.
- **A GA4 data filter blanks DebugView with no error.** Internal/Developer-traffic filters drop
  matching events; the stream just goes empty. When the account holds more than one property for the
  app, a filter change can land on the WRONG property — **Admin → Account change history** names the
  property that actually received it. Cost a full afternoon on 2026-08-19.
- **Conversion-action status lags.** The Conversions summary table shows a stale status while the
  action's own detail page is current. Trust the detail page.

## There is ONE Firebase↔Ads link, and GA4 owns it

Firebase → Project settings → Integrations → Google Ads is a read-only mirror ("Google Ads linking is
now managed within Google Analytics"). Don't hunt for a second link to repair. Verify at GA4 → Admin →
Product links → **Google Ads links**: account type must read **Account**, not Manager — if the Ads
account sits under an MCC, the property must be linked to the MANAGER, not the child.

**Google Play ↔ Ads is a DIFFERENT link.** Without it the Play-sourced installs conversion action
reads "Conversion data source is not linked" while still recording installs. Approve it in
**Play Console → Settings → Linked services** — no email reaches the Ads address, because the notice
goes to the Play account owner. The Play developer account must have exactly **one** Owner or linking
is unsupported.

## Server-side Measurement Protocol

MP events **are** exported to linked ad products — `session_id` is NOT required for that use case (it
is required only for User-ID assignment and session attribution, which is what the docs' session
guidance is about). Requirements: send ≤63 days after that user's latest online event, and if you
override `timestamp_micros` keep it inside 72h. Don't add `session_id` chasing an Ads gap.

Confirm delivery without GA4 access: the Worker writes `ga4:purchase:<transactionId>` to KV **only**
on a 2xx from MP (`workers/src/lib/ga4.ts`), so the key's presence proves the call was made and
accepted.

## Deleting a retired Firebase project

Deleting a Firebase project deletes its **GCP project and every OAuth client in it**. Before deleting
one, confirm no live client id carries its project number — Arul's web + Android client ids,
`google-services.json` and `GA4_FIREBASE_APP_ID` are all on `1083884444243`. A retired property can
also linger as a registered app conversion data source in Ads under an identical app name; pick data
sources by property NUMBER, never by app label.
