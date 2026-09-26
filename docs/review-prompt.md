# Review prompt — Play's in-app review sheet

Read before touching `lib/features/review/**` or the `armReviewPrompt` calls in the apply and set
notifiers.

## Policy — why there is no question in front of it

Google Play forbids asking the user's opinion before or while the sheet shows ("Enjoying Arul?",
star gating, "rate us 5 stars"). **Show Google's sheet and nothing else** — no pre-prompt, no
overlay, no button that calls the API. A rate-us row, if one is ever wanted, opens the Play listing
(`openStoreListing`), never `requestReview`: Play's quota silently drops a sheet, and a button that
does nothing reads as broken.

## Play tells us nothing

`requestReview()` completes the same way whether the sheet showed, Play's quota swallowed it, or the
user rated. **Never build a "did they rate?" branch** — there is no signal. So a completed call is
the only fact: it consumes the arm and takes a cap slot. A `PlatformException` means Play refused the
flow (no Play Store, no Activity), nothing was asked, and the arm and the slot are put back.

`isAvailable()` on Android is a `requestReviewFlow` round trip, not a local check — it can take
hundreds of ms. The surface is re-checked after it, because a permission dialog or a sheet can arrive
while Play answers.

## When it asks

- **Armed by a success, asked on a LATER cold open.** Static apply success, live apply reaching the
  chooser (its Set tap is unobservable — the same point `wallpaper_applied` counts), or a ringtone
  set. The arm is stamped with a per-process id; a resume never builds a new process, so it never
  qualifies. Failure, premium refusal and a trip to the write-settings grant arm nothing.
- **Boolean, not a count.** Ten sets in one launch buy one ask; each ask needs a fresh success.
- **Once per process.** The first evaluation decides; a skip leaves the arm for the next cold open.
- **Cap: 1 ask per rolling 30 days**, counted on our side. Play's quota may silently drop any second
  call inside a month, yet that call still spends the arm and fires `review_prompt_requested`.
- Arming must never fail a set that already succeeded: it is fire-and-forget behind a try.

## Where it asks — the guard

The one trigger is the feed, `reviewSettleDelay` (2 s) after its catalog first has data, so a late
post-frame surface (push permission, a paywall push, the update prompt) claims the screen first and
the guard sees it. Every one of these skips this cold open:

- anything above the feed in ANY navigator — `canPop()` walked up to the root. Never
  `ModalRoute.of`: it subscribes the feed, which would then rebuild on every sheet open and close;
- the Activity not `resumed` — OS permission dialogs, the wallpaper chooser and Play's own flows
  pause it without any Flutter route;
- a link or push landing this process: `ArulDeepLink.landedThisLaunch`, set by `requestTarget` and by
  `noteExternalOpen()` in `PushOpenHandler._open` (home, category and premium taps park no target).
  It stays true after the target is consumed;
- this launch's update check still undecided (it waits) or prompted (it skips) — the update wins
  ([app-update.md](app-update.md));
- the router not on `/browse`, known offline, the push-permission ask not yet spent, or an apply,
  share or ringtone set still loading.

## Analytics

`review_prompt_requested` (`trigger`: `wallpaper_static`|`wallpaper_live`|`ringtone`,
`requests_30d` as a string) is **GA4-only** — off the PostHog allow-list, which is journey-only. It
means "we asked Play", never "the user saw it" or "rated". Skips emit nothing.

## Verifying the real sheet

`flutter run`, a sideload or an emulator never shows it. Upload the `.aab` to **internal app
sharing** (or the internal track), install from that link with a Gmail tester account whose Play
library holds the app, then: set a ringtone or apply a wallpaper → force-stop → open cold → wait on
the feed. The sheet appears with **Submit disabled** outside production. Google's cure for a spent
quota is exactly those two routes. Once the account has installed from the internal track, local
builds on that device can reach the sheet too. A tester who already reviewed, a Workspace account,
a non-primary account selected in the Play Store, or a sideloaded Play Store sees nothing.
