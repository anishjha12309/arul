# Quick Access bar — the always-on shortcut notification

Read before touching `lib/features/quick_bar/**`, `android/**/quickbar/**` or the `quick_bar_*`
layouts. Channels and the permission ask: [notifications.md](notifications.md). Link routing:
[deep-links.md](deep-links.md).

## Owner decisions — the Play exposure is accepted, not overlooked

- **Copied from Noor (`~/prod-hsr-shubh`), minus its foreground service.** Play's FGS policy wants a
  user task that breaks if deferred; a shortcut bar has none, and `specialUse` needs a Play Console
  declaration plus a demo video under human review. A plain ongoing post is held by the system, survives
  the process dying, and needs no declaration. Core App Quality ("persistent only for ongoing events")
  and Google's Live Updates page ("quick access to app features" is inappropriate) still read against
  it — the owner shipped it anyway.
- **On by itself** once notifications are allowed (`QuickBarSetting.autoEnable`), the first time only:
  `arul_quick_bar_on` null = undecided, so a denial leaves it open and a later grant turns it on at the
  next resume. After any choice only the Settings toggle changes it.
- **A swipe re-posts it at once** (`deleteIntent` → `QuickBarReceiver`), against Google's "don't repost
  what the user dismissed". The receiver re-checks the stored switch, so an app-side `cancel()` (toggle
  off, kill switch) never comes back — `deleteIntent` fires on user dismissal only.
- **Kill switch: `app_config.feature_flags.quick_bar = false`** — a DB row, no deploy.
  `quickBarKillSwitch` persists it as `arul_quick_bar_killed`, so an offline launch keeps the last
  verdict instead of re-posting, and `autoEnable` waits for the config so a first launch never
  flashes a killed bar on.
- **Analytics, GA4-only (off the PostHog allow-list):** `quick_bar_toggled {enabled, via: auto|settings}`
  — `autoEnable` runs one call at a time, because the permission dialog closing is also a resume —
  and `deep_link_opened` with source `quick_bar` for a tap.

## What "sticky" can mean

Android 13 and below: an ongoing post cannot be swiped. Android 14+: anyone can swipe it while the
phone is unlocked — no app can stop that, Noor included; it holds only on the lock screen and through
Clear all (`FLAG_NO_CLEAR`). The re-post is what makes it come back.

## Traps

- **Two copies of the state.** Dart prefs are the truth; `QuickBar.sync` mirrors them and the labels
  into native prefs (`arul.quick_bar`) on every launch, resume and change, because the boot, update
  and dismiss paths run with no Flutter alive.
- **Collapsed custom content is capped at 48dp on Android 12+** — the collapsed root is a fixed 48dp
  (36dp buttons + 6dp padding). A `wrap_content` root lets the fitXY art's intrinsic size inflate it.
- **The banner's corners are baked into the art**, drawn fitXY: `android:clipToOutline` exists only
  from Android 12 and minSdk is 24. Re-cut with `python tools/quick_bar_art.py <SOURCE_DIR>`; the
  default `~/Anish/quickbar-art/` was not migrated to the Mac, and without a source the script writes
  gradient placeholders. The buttons are shape drawables, which draw their own corners everywhere.
- **A collapsed button is ~63dp on a 360dp phone** (half the audience; 320dp is the next real tier,
  and font scales 1.2–1.5 are common). `QuickBar.fitCollapsed` measures the labels and picks icon +
  label, label alone, or icon alone — chrome around the buttons measured 156dp on device. Expanded
  stacks icon over label, so the word gets the whole button. Labels are singular
  (`quickBarWallpaper`, not `tabWallpapers`) for the same width.
- **A tap is parked natively, never sent as a link.** When Android has killed the process but kept
  the task, it restores MainActivity with the OLD root intent and hands the tap to `onNewIntent`
  before the router exists; Flutter forwards the route and it is dropped (seen on device: the splash
  went to `/browse`). `QuickBar.capture` parks the tab, `QuickBarTaps` takes it on start and on every
  resume and routes it through `PushTapRouter`; the shell's `_followDeepLink` then fires
  `deep_link_opened` with source `quick_bar`.
  `onCreate` captures only without saved state, or a restored root intent replays an old tap. Never
  a receiver: Android 12+ blocks trampolines.
- **The lock-screen view is PUBLIC**, so the bar never carries a price or premium pitch: Play's
  Lockscreen Monetization policy bans monetizing the locked display.
- **Channel `arul_quick_access_v1` is LOW**, created natively at the first post — MIN drops the
  status-bar icon and sinks below the fold. Notification id 4000 clears the plugin's 3000+ and FCM's
  tag-keyed campaigns.
- **Noor's code reports Xiaomi hiding a plain post made in the same session the permission was
  granted** (unverified here) — the next launch re-posts, so it shows from the second open there.
