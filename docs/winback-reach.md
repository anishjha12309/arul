# ₹99 win-back reach — the doors no pay tap opens

Read before touching `winback_reach.dart`, `winback_ledger.dart`, `winback_daily_*`, `uninstall_shortcut_*`,
`android/**/shortcut/**`, `lib/core/launch/**` or `PremiumScreen`'s sheet-only branch. The offer itself:
[cancel-offer.md](cancel-offer.md) §The winback · the push: [winback-push.md](winback-push.md).

## Three doors, one rule (owner)

- **Premium tap**: a blocked apply/share/set/save opens `/premium?source=<gate>&offer=winback_99` when the
  CACHED `/me` is reachable (`premiumGateRoute`). Never await `/me` there, and read the config only for a
  reachable row: either would hold every new user's trial paywall. The one exception to the entitlement
  rule's "straight to `/premium`, no sheet".
- **Daily**: once per IST day, on a cold open, from the feed (`WinbackDailyTrigger`).
- **"Uninstall" launcher shortcut** (below).
- All three use `winbackReachable`: `!premium` + `winback_offer_eligible` + `trial_end` + status not `pending`.
  `pending` is mid-checkout, and outside `/premium` the purchase notifier is gone. Premium must have RUN OUT:
  an accepted winback starts a fresh month that day (`grantSetup`), so asking earlier throws paid days away.
- The push keeps `winbackOffered` (the Worker's flag alone): it deliberately asks a paid revoker a day before
  the period ends, over the Resubscribe page.

## No checkout nobody tapped

- New doors call `_winbackFirst` straight from `_openOfferAtOnce`, never `_startPaid`, and every way off the
  sheet only closes. "I don't want the offer" → ₹199 survives only on the pay button's own sheet
  (`entry == null`), where ₹199 is what they tapped; the push's decline only closes too.
- `_openOfferAtOnce` skips the reconcile wait (the door's caller already read `/me`), so there is no 5 s
  loading face. The push keeps it: its cached `/me` can predate the UPI revoke.

## Sheet-only doors (daily, Uninstall)

- `ArulOverlayPage`: non-opaque, no barrier colour, zero-length transitions, NOT a
  `MaterialRouteTransitionMixin`, so the page below runs no exit animation and stays painted; the route's
  `ModalBarrier` still blocks touches to it.
- `PremiumScreen` paints `SizedBox.expand()` until a purchase starts (`_revealed`): nothing ₹199 flashes and
  no `paywall_shown` or paywall-view fires. It still WATCHES `entitlementDetailProvider` under that frame:
  the open-time reconcile invalidates `/me`, an unwatched provider never rebuilds, and the door's await on
  `/me` hung forever.
- Any close without accept pops back (`_leave`); "Uninstall anyway" opens App info first. A premium tap
  keeps the paywall (they came for premium). These doors skip `_warmOnboardingVideo`: never trial-eligible.

## Daily cadence (owner)

- `WinbackLedger`, SharedPreferences on THIS phone: `arul_winback_shown_day` (IST day of the last ₹99 winback
  sheet from ANY door), `arul_winback_daily_dismissals`, `arul_winback_paused_until`. Two daily dismissals in
  a row → `paused_until = day + 7`, so seven days with none; an accept resets the count. Never an
  eligibility input: the one exception to cancel-offer's "no per-person record".
- IST is UTC + 5:30 (no DST). Days compare as `yyyy-MM-dd` strings, so a clock set backwards only waits longer.
- **One unrequested surface per launch** (`launchMomentProvider`): the push-permission ask claims it and is
  never held back; the daily claims it right before pushing; the review claims it right before `consume`
  and, refused, keeps its arm. The daily settles at 1.5 s against the review's 2 s, so it wins a launch both
  qualify for.
- The guard is the review's: `resumed`, `!landedThisLaunch`, `UpdateHolds` clear (waits while undecided),
  `reviewSurfaceIsTopmost`, `reviewHostReady` (feed on `/browse`, online, permission ask spent, nothing
  running). `/me` gets 8 s: a sheet rising over a long-settled feed is worse than none. One evaluation per
  process, so a blocked launch is spent.

## Countdown and switches

- The 10:00 hold shows on every door although the sheet comes back daily: a CCPA "false urgency" risk the
  owner accepted. `winback_reach.countdown: false` drops the pill and "Limited time pricing" together on the
  new doors; the push and the pay button keep both.
- `feature_flags.winback_reach.{tap_first, daily_sheet, uninstall_shortcut, countdown}`: ON unless exactly
  `false`, and an absent or loading config is ON. The doors ship live, so nothing is "activated remotely"
  (Play's Behavior Transparency rule). A change reaches a phone at its next cold start.

## The "Uninstall" shortcut

- **The label must stay true** (Play Deceptive Behavior: apps "perform as reasonably and accurately expected";
  CCPA bait-and-switch). Every tap ends at the ₹99 sheet with "Uninstall anyway", which opens App info and
  the phone's own Uninstall, or at App info itself: signed out, ineligible, switched off, on `/sign-in` or
  `/premium`, `/me` over 6 s, splash over 15 s. App info needs no permission; `REQUEST_DELETE_PACKAGES` is
  not declared (owner).
- Dynamic only, published by `uninstallShortcutSyncProvider` (root listener) while reachable and switched on,
  removed after a purchase or sign-out. No native call while `/me` or the config is loading or failed: an
  offline launch must neither retire a valid shortcut nor publish a killed one. Every resume re-runs it: a
  restored phone loses dynamic shortcuts, and background calls are rate-limited.
- **Never `disableShortcuts`**: a disabled pinned copy cannot launch, so its label would lie. A pinned copy
  outlives removal, so the native prefs mirror `offer_allowed: false` and `capture` opens App info at once,
  no Flutter needed. Retiring the shortcut for good = `disableShortcuts` with a message in that release.
- Delivery copies the Quick Access bar ([quick-bar.md](quick-bar.md)): explicit `MainActivity` intent,
  action `com.hsrutility.arul.shortcut.UNINSTALL`, NEW_TASK|CLEAR_TOP|SINGLE_TOP; captured in `onNewIntent`
  and in `onCreate` with no saved state; Dart takes it on start and every resume. A parked `offer` untaken
  in 15 s goes to App info. A warm tap over a PhonePe SDK page closes that page (CLEAR_TOP).
- `pushDynamicShortcut` runs only when the labels changed: it also reports a use. Labels follow the app's own
  language (`AppLocalizations.delegate.load`), so a phone-language change re-labels at the next foreground,
  not on `ACTION_LOCALE_CHANGED`. Deliberate.
- `ic_shortcut_uninstall` is referenced by `R` id, so it needs no `keep.xml` line. `quick_actions` was
  rejected: one string for both labels, `ACTION_RUN` + an extra, the icon looked up by name (R8 strips it),
  no parking for a restored task.

## Events (no new names)

`cancel_offer_*` with `flow: winback` carry `entry` ∈ `push|premium_tap|daily|uninstall_shortcut`; "Uninstall
anyway" is `cancel_offer_declined` `via: uninstall`. `deep_link_opened` `{kind: premium|app_info, source:
shortcut}` and `launch_source: shortcut` are GA4-only. GA4 reports `entry` only once it is registered as an
event-scoped custom dimension.

## Contracts

- [ ] An "Uninstall" tap ends at the ₹99 sheet with "Uninstall anyway", or at App info — signed out,
  ineligible, offline, pinned copy, cold, warm, process dead
- [ ] The shortcut exists only while reachable; gone after a purchase or a sign-out
- [ ] A decline on a door no pay tap opened never starts a checkout
- [ ] At most one unprompted ₹99 sheet per IST day and one unrequested surface per launch; two dismissals in
  a row → seven days with none
- [ ] A new user's premium tap opens the trial paywall with no wait
- [ ] Each `winback_reach` switch set to `false` removes its door at the next cold start

## Prove it on a device

`env/dev.json` points at the LIVE Worker: make a lapsed row on the local stack ([local-stack.md](local-stack.md)).

```bash
adb shell dumpsys shortcut | grep -E "Package: com.hsrutility.arul|winback_uninstall"
adb shell cmd shortcut reset-throttling
adb shell am force-stop com.hsrutility.arul && adb shell am start -n com.hsrutility.arul/.MainActivity \
  -a com.hsrutility.arul.shortcut.UNINSTALL                    # cold; drop the force-stop for warm
adb shell run-as com.hsrutility.arul sed -i '/arul_winback_/d' shared_prefs/FlutterSharedPreferences.xml
```
