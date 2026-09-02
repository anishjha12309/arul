# Google Ads / Firebase / GA4 — linkage and attribution traps

Read before diagnosing "conversions aren't showing in Ads". Event semantics and the one-source
conversion rule: [analytics-events.md](analytics-events.md) · consoles and logcat:
[analytics-ops.md](analytics-ops.md).

Conversions live in an Ads account SHARED with Pakiza, so **a campaign must pick its own app's
conversion action** — the account-default goal is the other app's. Arul imports exactly ONE GA4
conversion: **`trial_started`** (Primary — what App-campaign bidding targets). `purchase` is emitted
nowhere and must stay out: unmarked as a GA4 key event, and absent from the Ads import.

## Ads counts ONLY ad-attributed conversions

GA4 holding N key events does not mean Ads shows N — Ads records only the subset it can trace to an
ad click. **"Conversion has never received data" is usually TRUE, not a fault.** Before suspecting a
broken link, read the medium split: GA4 → Reports → Acquisition → **User acquisition** → the "Key
events" dropdown → pick the event → read the **cpc** row. Zero there means Ads is right and the
problem is traffic, not plumbing. Hours have gone into hunting a link fault that did not exist.

## App campaigns have NO conversion goals

`Settings → Goals → campaign-specific goal settings` exists for Search/Shopping/PMax/Demand Gen
**only**. Per the Google Ads API: *"You can only set the `selective_optimization` field of Campaign
on an App campaign. For all other campaign types, use campaign goals."* The App-campaign control is
**Settings → Bidding → "In-app actions"**, then the specific action — that is
`selective_optimization`. Account-default goals therefore cannot hijack an App campaign's bidding.

**Optimising toward an in-app action needs ≥10 distinct users/day on it** (Google's own floor; below
it they instruct you to pick a commoner action). `trial_started` is not a signup — it is a UPI
Autopay mandate authorisation with a real PIN entry — so it is bottom-funnel by construction.
**Re-read the current rate before assuming either way**, because the remedy differs: above the floor,
bid on `trial_started` directly; below it, bid on `checkout_started` (GA4 `begin_checkout`, fired at
the paywall tap) and keep `trial_started` as a measured conversion. A GA4 event is not an Ads
conversion until it is imported — adding one to the app changes nothing in Ads by itself.

## `value` without `currency` is silently discarded

GA4 drops `value` unless `currency` rides on the SAME event — the event still records, with
`ga_error(_err)=19` / `ga_error_value(_ev)=currency` — and Ads then books the conversion action's
fallback (₹1, per its "if there's no value" setting). `_clean()` in `google_analytics_service.dart`
pairs INR with every surviving `value`; **never add a valued event on a path that bypasses it.** The
fastest way to confirm the bug is back is the asymmetry between a raw event at ₹0 and an event that
passes currency explicitly at its real value.

## Consoles lie in specific ways

- **Firebase DebugView has no key-event flag** — it renders every event identically. Only **GA4's**
  DebugView marks key events (green flag / `firebase_conversion` param). Never judge key-event status
  from Firebase.
- **A GA4 data filter blanks DebugView with no error.** Internal/Developer-traffic filters drop
  matching events and the stream just goes empty. When the account holds more than one property for
  the app, a filter change can land on the WRONG property — **Admin → Account change history** names
  the property that actually received it.
- **Conversion-action status lags.** The Conversions summary table shows a stale status while the
  action's own detail page is current. Trust the detail page.

## Consent-mode defaults are load-bearing for attribution

GA4 attributes a session's source/medium only when the event stream carries the consent-mode v2
signals; with none set (Google: "by default, no consent mode values are set") every conversion lands
under **`(not set)`** in User acquisition. Google Ads still counts its own click-matched conversions,
so Ads can look healthy while GA4's cpc row reads 0. The four `google_analytics_default_allow_*`
manifest keys (all `true`, India-only app) are the fix, and they **must be manifest meta-data, not a
Dart `setConsent()`** — `first_open` fires before Dart runs. Validate on device: logcat
`FA-SVC … Setting DMA consent … source=MANIFEST, ad_user_data=granted`. Reports heal a day or two
after the build reaches users; nothing backfills.

**A first-user-source of `(not set)` on a day less than about 48 h old is Google's own processing
window, not a consent fault.** Re-read the day once it has settled before concluding anything.

## There is ONE Firebase↔Ads link, and GA4 owns it

Firebase → Project settings → Integrations → Google Ads is a read-only mirror ("Google Ads linking is
now managed within Google Analytics"). Don't hunt for a second link to repair. Verify at GA4 → Admin
→ Product links → **Google Ads links**: account type must read **Account**, not Manager — if the Ads
account sits under an MCC, the property must be linked to the MANAGER, not the child.

**Google Play ↔ Ads is a DIFFERENT link.** Without it the Play-sourced installs conversion action
reads "Conversion data source is not linked" while still recording installs. Approve it in **Play
Console → Settings → Linked services** — no email reaches the Ads address, because the notice goes to
the Play account owner. The Play developer account must have exactly **one** Owner or linking is
unsupported.

## Server-side Measurement Protocol — REMOVED, do not re-add

The Worker sends no GA4 event at all. MP events *are* exported to linked ad products and the wiring
worked — that was never the problem; the problem is the two-source rule in
[analytics-events.md](analytics-events.md). If MP is ever revived: `session_id` is NOT required for
ad export (only for User-ID assignment and session attribution); send within 63 days of the user's
latest online event; keep any `timestamp_micros` override inside 72 h. **And it must be the ONLY
source for whatever event it sends.**

## Deleting a retired Firebase project

Deleting a Firebase project deletes its **GCP project and every OAuth client in it**. Before deleting
one, confirm no live client id carries its project number — Arul's web and Android client ids and
`google-services.json` share a single project number. A retired property can also linger as a
registered app conversion data source in Ads under an identical app name; **pick data sources by
property NUMBER, never by app label.**
