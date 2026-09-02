---
description: One conversion action has one data source; the PostHog allow-list is default-deny.
paths:
  - "lib/core/analytics/**"
  - "workers/src/lib/posthog.ts"
---

- **Never call SDKs from widgets — always `AnalyticsService`.** The one deliberate exception is the
  hand-emitted install event in `main.dart`.
- **ONE conversion action, ONE data source.** `purchase` and Meta `Subscribe` are emitted NOWHERE and
  must not come back: two source types on one action desynchronised campaign attribution while raw
  counts stayed correct. `trial_started`/StartTrial is the only event campaigns bid on — app SDK,
  in-session. **Never add a server-side copy of a client conversion.** Accepted cost: no revenue or
  ROAS signal on either platform; revenue truth is Neon.
- **The PostHog allow-list is default-deny and pinned as an exact set** by
  `test/core/analytics_gating_test.dart`. A new `track()` call site costs nothing until it is added.
  Re-adding an event is a decision, not a cleanup.
- **Widening the cohort rate is safe; narrowing is not.** The stored value is the draw, not a
  boolean, so raising the rate only adds installs while lowering it drops every install whose draw
  exceeds the new rate and makes any spanning cohort discontinuous.
- `captureApplicationLifecycleEvents = false` is all-or-nothing and is the ONLY control over the
  SDK's native lifecycle events; the install event is re-emitted by hand under the SDK's own name.
- **Analytics is never a ranking source** — the feed orders on counters counted server-side in
  `/media/signed-url`, never on `wallpaper_applied`.
- Free-text properties stay ≤100 chars; GA4 silently drops longer values. A custom parameter is
  invisible to every GA4 report until it is registered as a custom dimension.

Read [docs/analytics-events.md](../../docs/analytics-events.md) for the event semantics and
[docs/analytics-ops.md](../../docs/analytics-ops.md) for the consoles.
