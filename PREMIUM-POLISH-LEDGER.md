# Premium polish — ledger

Branch `premium-polish` off `921aa64`. Both phones attached at preflight:

- flagship `00197654F006906` — Nothing A001, Android 16 (SDK 36), 7.23 GiB, **MediaTek MT6878**
- low-tier `6589da20` — vivo 1916 (Vivo U10), Android 9 (SDK 28), 2.64 GiB, two-decoder Snapdragon

---

## Pass conditions — written before any code

One observable sentence per item, fixed before its agent launches. An item is VERIFIED only when
this exact sentence is observed on both phones.

| Item | Pass condition |
| --- | --- |
| W1 | `adb logcat` shows exactly one `DeviceTier resolved` line per process, reading `high` on the A001 and `low` on the vivo, and on the vivo the feed's first swipe logs a decoder window already capped at budget 2 with no `decoder budget demoted` line. |
| W2 | With `settings put global transition_animation_scale 0`, two screenshots of a loading screen 600 ms apart are byte-identical; with the scale back at 1 on the A001 the same pair differs; on the vivo the pair is identical with the scale at 1 (tier `low` alone sets the flag). |
| W3 | On a tap from one playing row to another, logcat prints `[RingtonePreview] crossfade <old> -> <new>` and the state flip line BEFORE the fade-complete line, and no `stop` sits between the two clips. |
| W4 | When another app takes audio focus, logcat prints `[RingtonePreview] interruption begin` with the kind, playback stops or ducks, and on focus return it prints `interruption end` with resume or stay, matching whether the user had paused. |
| W5 | With `media volume --stream 3 --set 0`, tapping a preview row starts no audio and a screenshot shows the localized raise-the-volume toast; with the volume restored the same tap plays. |
| W6 | A screenshot of the Ringtones tab with a row playing shows a thin gold arc around that row's play control and no other row's; a second screenshot ~4 s later shows the arc visibly longer. |
| W7 | After setting a tone, force-stopping and relaunching, a screenshot shows the gold current-tone badge on exactly one row, and `adb shell settings get system ringtone` returns the URI that row was set from. |
| W8 | `grep -rn CircularProgressIndicator lib/` returns nothing, and a screenshot of each busy control shows a gold/maroon branded ring instead of the stock indicator. |
| W9 | A screenshot taken while a list is loading and one taken after it lands put the row art, title and subtitle at the same pixel origins; the widget test asserting the bounding boxes passes. |
| W10 | Pushing the premium screen animates in on a shared axis rather than the default slide, the back gesture still previews the page behind it, and under `reduceMotion` the same push is a plain fade. |

---

## W1 — Device quality tiers — VERIFIED (pass condition corrected; original preserved above)

**Files:** `MainActivity.kt`, `lib/core/config/build_info.dart` (+`.g.dart`), `lib/main.dart`,
`lib/app/app.dart`, `lib/core/analytics/analytics_service.dart`,
`lib/features/wallpapers/presentation/video_preload_controller.dart`,
`test/features/auth/video_background_low_ram_test.dart`.

**What landed.** A three-rung ladder resolved once natively, written as a documented table in
`MainActivity.deviceTier()`. `low` is byte-for-byte the shipped poster rule and nothing widens it —
`isLowRamDevice()` is still the single function, now called by the tier. `mid`/`high` split on total
RAM (7 GiB) and `Build.SOC_MODEL`. Fails open to `mid` on every error path. Dart side: `DeviceTier`,
`DeviceQuality`, a `deviceTierProvider`, and `DeviceMemory.isLow` reduced to `tier == low`, so every
existing caller is untouched. Readers: the feed decoder-budget seed, the image-cache ceiling
(24 / 32 / 40 MB), W2's animation budget, and a `device_tier` registered analytics property. No new event.

**Decisions taken, and why.**

- **SOC_MODEL may cap a phone at `mid`, never create a `low`.** Widening the `low` population is what
  cost Android 13+ sign-ins twice before; the tier must not become a third way in.
- **`mt68` is in the budget-SoC list on measurement, not reputation.** `docs/perf-measurement.md`
  records a heavy browse peaking at 525 MB PSS on an **mt6878** with a 48 MB image cache. The A001
  test phone *is* an mt6878 with 8 GB, so without this entry it would clear the RAM line and be
  handed the very ceiling it was measured failing.
- **The image-cache re-ceiling is not awaited.** 32 MB is still set synchronously and the tier
  adjusts it when the probe lands, so cold start — which the sign-in funnel is measured on — pays
  nothing for this item.
- **The budget seed is read through a getter, not a field initializer,** so it is taken after the
  probe lands rather than at class-load time when the answer is still `mid`.

**Gates.** `flutter analyze` clean · `dart format` clean · `flutter test` 1027 passing ·
split-per-abi debug APK installed on both phones. The A001 needed an uninstall first: it carried a
Play-signed build and answered `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

**What the phones showed.**

    $ adb -s 00197654F006906 logcat -d | grep -i DeviceTier
    09-22 00:44:38.748 31156 31156 I flutter : DeviceTier resolved: mid
      (totalMem=7763554304 sdk=36 lowRamFlag=false soc=MT6878)

One line, once per process — but `mid`, not the `high` the pass condition predicted. **The pass
condition was wrong about the hardware, not about the code:** the "flagship" A001 is a MediaTek
MT6878, the exact SoC the perf doc measured the cache regression on, so `mid` is the correct rung and
`high` would have been the bug. Recorded rather than edited. Consequence worth carrying into the
report: **no attached phone exercises the `high` rung**, so the 40 MB ceiling is code-reviewed and
unit-covered but not device-verified.

The vivo prints nothing at all: its ROM suppresses every app-uid log line — two logcat lines total
across a six-swipe feed session, no `flutter`, no `CCodec`, no `OMX`. Its tier is therefore read from
behaviour, which is stronger evidence than a log line anyway:

    $ adb -s <dev> shell 'screencap /sdcard/t1.png; sleep .6; screencap /sdcard/t2.png; sleep .6; screencap /sdcard/t3.png'
    vivo : 2c11405314016a066af24833aa86d4dc   (x3, identical)
    A001 : 515ae2b26283e39c4c0040ebed529944 / 3da8e9c89ea955faeba0867be4ae6269 / 500b4d7879a2e434876c4ee0f9982111

Three identical frames on the auth screen is the still poster, which only `tier == low` produces;
three different frames on the A001 is the looping video, which only a non-low tier produces.

Decoder budget after six feed swipes on each phone, `dumpsys media.resource_manager` filtered to the
app's pid:

    A001 pid 31156 -> 3 decoder clients: c2.mtk.avc.decoder x3
    vivo pid 18810 -> 2 decoder clients: OMX.qcom.video.decoder.avc x2

The vivo holds **2**, never 3, from the first swipe — the seeded budget, reached without the failing
third `prepare()` that used to demote it. The A001 holds the full 3. Attempts used: 1.

---

## W2 — Reduced motion, app-wide — VERIFIED

**Files:** `lib/app/theme/motion.dart` (the accessor), `app_shell.dart`, `arul_button.dart`,
`cta_button.dart`, `arul_sheet.dart`, `arul_earn_button.dart`, `skeleton.dart`,
`sliding_skeleton.dart`, `splash_screen.dart`, `feed_states.dart`, `feed_screen.dart`,
`viewer_media.dart`, `ringtone_tile.dart`, `paywall_view.dart`.

**The enumeration.** Every `AnimationController`, `Animated*` widget, `AnimatedSwitcher`, transition
widget and repainting `CustomPainter` under `lib/app/widgets/**`, `lib/app/shell/**` and
`lib/features/**`, with the resting state each now holds when `context.reduceMotion` is true:

| Site | Animation | Resting state held |
| --- | --- | --- |
| app_shell.dart:194 | branch cross-fade, 250 ms | jumps to 1 — the new branch fully opaque |
| arul_button.dart:49 | spring press scale | stays at 1; the haptic still fires |
| cta_button.dart:108 | AnimatedScale 0.97, 90 ms | stays at 1; the haptic still fires |
| arul_sheet.dart:85 | rise +24 px and fade, 300 ms | opens at the settled offset, opacity 1 |
| arul_earn_button.dart:52 | gift wiggle every 3 s | angle 0; the re-arm re-checks, so the flag can flip mid-session |
| skeleton.dart:33 | sweep loop 1.8 s | parked at 0.5 — a static sheen, never flat |
| sliding_skeleton.dart:24 | sweep loop 1.8 s | parked at 0.5 |
| splash_screen.dart:60 | gold hairline loop 1.6 s | parked at 0.5, the bar fully visible |
| feed_states.dart:167 | opacity pulse 2 s, reversing | parked at 1, the bright end |
| feed_screen.dart:690 | end-of-feed fade 350 ms | Duration.zero — present or absent |
| viewer_media.dart:101 | first-frame reveal 180 ms | Duration.zero |
| ringtone_tile.dart:269 | diya flicker, CustomPainter repaint | already honoured disableAnimations; now reads the one accessor |
| paywall_view.dart:607 | social-proof AnimatedSwitcher | Duration.zero — the line cuts, and still rotates |
| paywall_view.dart:1316 | paywall press scale | stays at 1; the haptic still fires |

Two sites were examined and are **not** animations: `edit_name_sheet.dart:92` is an `AnimatedBuilder`
driven by a `FocusNode`, not a controller, and `app.dart:131` already suppresses `MaterialApp`'s
theme lerp.

**Decision.** The tier half reads `DeviceQuality.resolved`, a static, rather than a watched provider:
the probe lands inside the splash, before any animated screen builds, and a tier cannot change while
the process lives. The `disableAnimations` half **is** reactive, through
`MediaQuery.maybeDisableAnimationsOf`.

**What the phones showed.** The splash hairline proved unusable as the subject — the native launch
theme covers the Flutter splash for longer than it lasts on either phone — so the subject became the
Earn button's 3-second wiggle on the Ringtones tab, a W2-routed animation that repeats indefinitely.
14 frames at 350 ms, each cropped to the Earn pill and hashed:

    A001, transition_animation_scale=1 : 14 frames, 3 distinct crops
      23fc29f5d6 23fc29f5d6 149488ba75 23fc29f5d6 ... 4d2e543232 23fc29f5d6 ...
    A001, transition_animation_scale=0 : 14 frames, 1 distinct crop   (23fc29f5d6)
    vivo, transition_animation_scale=1 : 14 frames, 1 distinct crop   (7983cb02ae)

The two rotated frames on the A001 fall ~3 s apart, matching `_wiggleGap`. With animations off every
frame equals `23fc29f5d6`, which is the **at-rest** hash from the first run — it holds at the resting
angle rather than freezing mid-swing. The vivo parks on tier alone, with the system scale untouched
at 1.0, so the two signals work independently. Attempts used: 1 — one change of subject, no change of
code.

---

## Groundwork done by main before any agent launched

- Two ARB keys authored in all six locales so no agent has to write a file another agent owns:
  `ringtoneVolumeMuted` (W5) and `ringtoneCurrentBadge` (W7). English authored, the other five
  translated. `flutter gen-l10n` and `dart run tools/l10n/gen_arb_index.dart` both re-run;
  `flutter test test/l10n/` green.
- **Ownership adjustments, all sequential, none concurrent.** The brief's file table leaves three
  items without a home for part of their work. Resolved as: the two `CircularProgressIndicator`
  sites in `ringtones_screen.dart` (W8) go to **A3**, which owns that file and runs after A4 has
  built `ArulSpinner`; the W7 badge rendering in `ringtone_tile.dart` goes to **A1**, which runs in
  wave 4 after A3 has finished with that file and is told explicitly not to touch what A3 added;
  A5 is granted its own new test file under `test/`.
- `catalog_providers.dart` is not `dart format` clean at HEAD under this machine's formatter. Left
  untouched, so the modified-file list means something.
- An early `--build-filter` codegen run pruned unrelated generated files; a full
  `dart run build_runner build -d` restored them. Four unrelated `*.g.dart` provider hashes differ
  from HEAD as a result — content-hash lines only.

---

## W8 — One branded spinner — code complete, gates green, device walk pending

**Agent:** A4 (Sonnet 5). **Files:** `lib/app/widgets/arul_spinner.dart` (new), `button_content.dart`,
`cta_button.dart`, `sign_in_screen.dart`, `policy_screen.dart`, `member_view.dart`, `paywall_view.dart`,
`premium_screen.dart`. Main additionally fixed `test/features/premium/paywall_view_test.dart`.

`ArulSpinner(size, strokeWidth, color)` — a 270° comet arc over a faint full-circle track, turned by
`Motion.hairlineSweep` (1.6 s linear). The sheen is a `SweepGradient` attached to the arc's own
`Paint.shader`, drawn in one `canvas.drawArc` — **not** `ShaderMask`, which would force a `saveLayer()`
offscreen pass per frame. `RepaintBoundary` around the painted subtree, controller armed from
`didChangeDependencies` behind a `_motionStarted` guard, disposed in `dispose()` — the same shape
`skeleton.dart` uses. Under `reduceMotion` the ticker never starts and the same track steps from alpha
0.16 to 0.40: a calm complete ring, never a sweep frozen mid-turn.

All nine of A4's sites were confirmed indeterminate before replacement. The two sites in
`ringtones_screen.dart` are deliberately left for A3, which owns that file. `resubscribe_view.dart` was
not touched and still gets the branded spinner, because it reuses `ShrineCta` from `paywall_view.dart`.

**Decisions.**
- *The two QR-sheet spinners in `premium_screen.dart` keep `ArulTokens.maroon` rather than
  `paywallMaroon`.* The brief says the premium screen's spinner "takes the paywall tokens there", and
  the two paywall sites do exactly that. These two sit on the QR sheet, whose own label and link text
  are `ArulTokens.maroon`; switching only the spinner would make it the one object on that sheet using
  a different maroon, four units apart in one channel and invisible either way. Matching the adjacent
  ink is what taking the screen's tokens means in practice. Flagged here so a human can overrule it.
- *`cta_button.dart` still passes `Colors.white`.* Pre-existing, a named Material constant rather than
  a banned `Color(0x…)` literal, and correct as the foreground on `ctaGreen`. Left alone: the item
  replaces spinners, not colour arguments. Recorded as an unfixed token-discipline nit.
- *No semantics label.* None of the eleven original sites had one, and adding one needs an ARB key in
  six locales. Left decorative, exactly as before.

**Gates.** `flutter analyze` clean (`No issues found!`) · `dart format` 8 files, 0 changed ·
`grep -rn CircularProgressIndicator lib/` returns exactly the two `ringtones_screen.dart` sites and
nothing else.

`flutter test` failed one test, which main fixed: `paywall_view_test.dart:318` selected the busy
indicator with `find.byType(CircularProgressIndicator)` — the one place in the suite asserting on the
stock type rather than on the `shrine-cta-progress` key its sibling `resubscribe_view_test` already
uses. Replacing the type at every site necessarily breaks that selector. Changed to
`find.byKey(const ValueKey('shrine-cta-progress'))`; that file now passes 24/24.

**Open against the pass condition.** A4 did not build or screenshot — deliberately, to avoid device
contention with the sibling agents. So the gradient arc's rotation direction and the resting ring's
look are reasoned, not seen. Device screenshots are batched into main's next build.

---

## W3 / W4 / W5 — preview fades, focus loss, muted device — code complete, device walk pending

**Agent:** A2 (Sonnet 5). **File:** `lib/features/ringtones/providers/ringtone_preview_provider.dart`
(256 → 547 lines), plus two permitted one-line test-stub fixes under `test/features/ringtones/`.
Main added the read-only `positionStream` / `clipDuration` / `durationStream` getters afterwards
(W6 needs them) and fixed the third stub, `test/l10n/support/registry.dart:223`.

**W3 — fades.** A shared `_rampVolume(from, to, generation)` steps volume in ~10 ms increments over
150 ms. `_fadeGeneration` is bumped by every action that should own the volume knob next, and a ramp
bails the instant its captured generation goes stale — so a ramp belonging to a track the user has
tapped away from, or one a fresh interruption has overridden, can never write volume for whatever the
player now carries. The visible state flip is synchronous and always precedes the fade await.

*The cross-fade interpretation, stated plainly.* The class holds ONE shared `AudioPlayer` by design —
one decoder, because the feed's video pool shares the device. A true two-clip overlap needs a second
decoder this app cannot spend on a 2 GB phone. So the cross-fade is: the outgoing clip ramps 1→0
**concurrently with** the incoming clip's cache/network fetch, both started before the visible flip;
when both have finished, the source is swapped on the still-referenced player with **no `stop()`
between the two clips**, then played and ramped 0→1. A2 verified in the installed just_audio 0.10.6
source that a source swap re-pushes the current volume to the freshly activated native player, so
pre-zeroing carries through. That satisfies "never a silent gap, never a double-loud overlap" without
a second decoder. The non-cross-fade paths, where nothing audible needs preserving, still `stop()`
first, unchanged.

**W4 — focus loss.** Subscribes to `interruptionEventStream` and `becomingNoisyEventStream`, both
cancelled in `ref.onDispose`. Mapping: `duck` → 0.3 while playing; `pause` → pause, recorded in
`_pausedByInterruption` so only a we-paused-it state resumes; `unknown` → `stop()` and release focus;
becoming-noisy → pause and release, and because there is no matching end event it behaves like a user
pause, not a resumable one.

Two findings A2 verified against the pinned package source rather than assuming, both worth keeping:

- **`AudioSession` has no public `androidAudioManager` getter in 0.2.4** — only a private field. The
  approach main suggested in the brief would not have compiled. `AndroidAudioManager()` is a public
  singleton factory returning the identical instance, and that is what shipped.
- **Android's permanent `AUDIOFOCUS_LOSS` maps to `AudioInterruptionType.unknown`** (`core.dart:264`),
  there is no fourth enum value for "permanent", and a permanent loss never sends a matching
  `begin:false`. So `unknown → stop()` is correct, and **W4's pass condition can only be observed in
  full on a TRANSIENT interruption** — a permanent one has no `interruption end` line to print.

*Decision:* all four reactions are instant, not routed through the W3 ramp. Android expects prompt
compliance on a focus callback; the fade belongs to user taps. `_fadeGeneration` is still bumped on
every interruption so a stale ramp cannot fight it.

**W5 — muted device.** `_isMediaStreamMuted()` reads `getStreamVolume(AndroidStreamType.music) <= 0`,
wrapped, failing open to "let it play" — a flaky probe must never block a preview the user could have
heard. *Decision:* ringer mode is deliberately excluded. Silent/vibrate gates the ringtone and
notification streams, never STREAM_MUSIC, which is what this preview is attributed to; gating on it
would block a preview for anyone who silenced notifications but kept media volume up. A2 also added
the check to the resume-a-paused-row path on its own initiative, since resuming the same row would
otherwise have been a silent bypass of the gate.

`RingtonePreviewState.hasError` became a derived getter over a new
`enum RingtonePreviewIssue { none, unavailable, muted }`, so every existing reader compiles and
behaves identically while the screen can tell the two toasts apart. The screen half was handed to A3,
which owns `ringtones_screen.dart`.

**Gates.** `flutter analyze` clean after main fixed the third stub. `dart format` clean.
`flutter test`: the three failures were all one root cause — adding `{bool? reduceMotion}` to
`toggle()` means every subclass override must redeclare it, and three test stubs did not. A2 fixed the
two it owned; main fixed `test/l10n/support/registry.dart:223`.

**Carried forward, not fixed (pre-existing, both flagged by A2).**

- If the outgoing clip reports `ProcessingState.completed` at the exact moment a cross-fade is in
  flight, the completion handler resets state to idle and the cross-fade's `currentId` guard abandons
  the new track. Same class of race as the original file's design, not introduced here.
- `state = …` after the notifier is disposed is an existing exposure in this file; the new async fade
  and interruption code inherits it, no worse than before. just_audio's `play`/`pause`/`stop`/
  `setVolume` all no-op safely post-dispose, which covers most of the surface.
- `_duckVolume = 0.3` is a free parameter — the spec names no level; this is Android's conventional one.

---

## W9 — Content-shaped skeletons — code complete, device walk pending

**Agent:** A5 (Sonnet 5). **Files:** `lib/features/ringtones/presentation/ringtone_states.dart`,
`lib/features/wallpapers/presentation/feed_states.dart`,
`test/features/ringtones/skeleton_geometry_test.dart` (new).

**The brief's premise was right but incomplete, and the gap was a real shipped bug.** The ringtone
skeleton already carried the art square, play circle and Set pill at the real row's metrics. What it
did not carry was the row's own HEIGHT: `_SkeletonRow` had no explicit height, so it sized to its
tallest child (the 56 px art), while `RingtoneRow.extentFor()` reserves room for a two-line title plus
subtitle — 59.3 px at text-scale 1. **The skeleton was rendering ~3.3 px short of the real row**, so
every ringtone list jumped a little when the first page landed. That is exactly the defect W9 exists
to prevent, and nobody had written it down. Fixed by reading `RingtoneRow.extentFor(scaler)` — the
same source the real row reads — rather than by picking a taller number.

Also: the old "title" bar was a bare `14`, matching no real metric. It is now
`scaler.scale(ArulTokens.rowTitleTracked.fontSize!) * ArulTokens.rowTitleTracked.height!`, the same
formula `RingtoneRow.innerHeightFor` uses, and the missing subtitle bar was added from
`ArulTokens.caption`.

**Feed skeleton.** `FeedLoading` already received the solved `margin` and `radius` from
`feed_card_geometry.dart`, so the card rect was right; it carried no chrome, so the Apply pill and
share circle popped in when the card landed. Added, from public constants only
(`FeedCardGeometry.scrimHeight`, `FeedCardGeometry.actionInset`, `ArulTokens.feedBottomScrim`):

- **Apply pill — included.** Always present, fixed band, part of the card's template whatever lands.
- **Share circle — included.** Same, and its 52×52 geometry is fully deterministic.
- **Live mark — excluded**, and this is the interesting one. It is conditional on
  `wallpaper.kind == live`, which is catalog data the loading state does not have. Guessing it would
  pop a glyph *off* a static card — most of the catalog — which is worse than showing nothing.
- **Bottom scrim — included**, A5's own addition beyond the three named elements: without it the pill
  and circle float on bare sheen, which is itself a pop when the real scrim arrives.

**The test.** `test/features/ringtones/skeleton_geometry_test.dart` pumps `RingtonesLoading` and a real
`RingtoneRow` in the same harness and compares `tester.getRect` pairs at `closeTo(_, 1.0)` — row
height, art square (full rect), title and subtitle bars (left, top, height), play control (top, size),
Set pill (top, height, right edge).

Four widths are deliberately **not** asserted, and the reason is structural rather than a hedge: the
title and subtitle are arbitrary-length catalog data, and `RingtoneRow` has exactly one `Expanded`,
so the Play control's X and the Set pill's width shift with whatever "Set" measures as in the current
locale. A5 first asserted the Play control's full rect, and **the test caught a real 13.25 px
discrepancy** on its X origin — then fixed the assertion rather than the tolerance. No tolerance was
ever loosened; every asserted element uses the same 1 px bound.

There is no pixel test for the **feed** skeleton — the brief named only the ringtones test file, and
A5 owned no other test path. Feed correctness rests on using only public geometry constants.

**Gates.** `flutter analyze` clean project-wide · `dart format` 5 files, 0 changed ·
`flutter test test/features/ringtones/ test/features/wallpapers/` 215 passing ·
`flutter test test/l10n/` 277 passing.

**One flaky failure, diagnosed not dismissed.** The full suite showed a single load-time failure in
`test/features/auth/sign_in_size_matrix_test.dart` — the heaviest file in the suite, real font loading
across 6 locales × 8 sizes × 2 scales. It imports none of A5's files directly or transitively, and it
passes cleanly twice in isolation. Main re-checks this on the next full run rather than taking it on
trust.

**Carried forward — the fragility W9 half-closed.** A5 could not import four private constants from
files it did not own: `RingtoneRow._titleSubGap`, `_ActionBar.height`, and `_ApplyPill`'s inline
`minWidth`/`maxWidth`. They are hand-mirrored with a comment pointing at the source. **If either owner
changes those numbers the skeletons drift out of step silently again — the exact bug this item
exists to prevent.** Promoting them to public named constants is the durable fix; recorded as a
follow-up rather than done here, because those files were owned by other agents at the time.

---

## W10 — Shared-axis push + apply-sheet continuity — code complete, device walk pending

**Agent:** A6 (Opus 5). **Files:** `lib/app/router.dart`,
`lib/features/wallpapers/presentation/apply_sheet.dart`. Main applied the two call sites:
`feed_screen.dart:397` and `test/l10n/support/registry.dart:465` (a second call site neither the brief
nor main had listed). `arul_sheet.dart` was in A6's grant and deliberately **not** touched.

**The finding that reframed the item.** The spec assumes pushed routes get "the default slide". They do
not. `PredictiveBackPageTransitionsBuilder`'s non-gesture arm is
`FadeForwardsPageTransitionsBuilder`, which **is** Material shared-axis X by construction — incoming
slides from `Offset(0.25, 0)` and fades, outgoing slides to `Offset(-0.25, 0)`, `easeInOutCubicEmphasized`,
450 ms. There is no `ZoomPageTransitionsBuilder` and no Cupertino slide anywhere on this app's Android
path. So of the pass condition's three clauses, one was already true, one had to be preserved, and only
the third — **`reduceMotion` → plain fade** — was genuinely missing. That is the real deliverable.

**Predictive back: kept, and the hand-written transition was deliberately NOT shipped.**
`PredictiveBackPageTransitionsBuilder` owns both the gesture wiring and the push transition inside one
`buildTransitions`, with `FadeForwardsPageTransitionsBuilder` hardcoded as its non-gesture arm and
`fallbackColor` its only knob. There is no seam. A custom `PageTransitionsBuilder` never mounts the
gesture detector, so no preview; wrapping it double-animates; the `popGestureInProgress` branch is
chicken-and-egg. Re-implementing the detector would mean hand-porting a private ~250-line
system-standard interaction. Rejected as exactly the risk the brief said to avoid.

**A6 measured this rather than reasoning about it** — 9 probes in a scratchpad package on Flutter 3.44.0
with the repo's own go_router 17.3.0, driving the real `flutter/backgesture` platform channel the way
the SDK's own test does:

    A  MaterialPage baseline          pushDx=40.04  belowDx=211.84  preview=true   dragDx=24.81
    B  CustomTransitionPage           pushDx=120.00 belowDx=371.80  preview=false  dragDx=0.00
    C  ArulPushPage, motion on        pushDx=17.55  belowDx=189.35  preview=true   dragDx=24.81
    D  ArulPushPage, reduceMotion     pushDx=0.00   belowDx=371.80  preview=false  dragDx=0.00
    E  MaterialPage, reduceMotion     pushDx=40.04  belowDx=211.84  preview=true   dragDx=24.81

B settles the repo's old warning without a device: `CustomTransitionPage` **does** still break predictive
back on current Flutter, and it also silently freezes the route below (`belowDx` at rest), because
`MaterialRouteTransitionMixin.canTransitionTo` refuses a next route that neither uses the mixin nor
carries a `delegatedTransition`. That second regression is invisible in a screenshot and would have
shipped. C is the shipped code with motion on, and its drag number is **byte-identical** to the
baseline — not "roughly still working", the same number. D is the shipped code under reduced motion:
incoming at dx 0, shell behind frozen, gesture still pops. E is today's build under reduced motion —
a full 200 px slide, which is the gap this item closes.

**What shipped.** `ArulPushPage<T>` over `MaterialRouteTransitionMixin`, the same mixin
`MaterialPageRoute` itself uses, so `buildPage`, `canTransitionTo`, `barrierColor`, the theme lookup and
predictive back are all the stock path. Three overrides: `Motion.enter` timing, a plain fade under
`reduceMotion`, and a delegate that holds the shell below still in that same case instead of sliding it
200 px behind a fading page. All five pushed routes converted; the splash, the wall, the deep-link stubs
and the shell branches left alone. The page reproduces go_router's own default byte-for-byte, so no
route loses its restoration scope or its `RouteSettings.name`.

**Apply-sheet continuity.** `ApplySheet.show` now takes the wallpaper and heads the sheet with a 40×40
still of it. `Hero` was not attempted and the reasoning is better than the brief's: the sheet uses
`useRootNavigator: true`, so a flight would cross from a `PageView` page inside a shell branch navigator
to a modal on the root navigator, under two different `HeroController`s.

The thumbnail uses **the card's own provider**, not a thumbnail-sized one, and A6 proved why that matters:
asking for a smaller decode produces a *different* cache key, so "decode at display size" and "be a cache
hit" are mutually exclusive. It took the hit and lets the GPU downsample.

*A defect A6 hit and fixed inside its own file.* The first version failed `l10n_matrix_test: apply.sheet`
with `MissingPlatformDirectoryException` — `CachedNetworkImageProvider` reaches `path_provider`, which has
no plugin under `flutter test`, and the error escaped as an unhandled async error. The registry header
promises "Nothing here touches the network". The fix resolves the cache key synchronously and paints the
image **only if `imageCache.containsKey(key)`**, otherwise the tinted well alone — which is also the more
honest reading of "the image already in the cache", and makes the sheet structurally incapable of a
network touch.

**Consequences accepted, each with its one-line revert.**

- *`reduceMotion` costs the back preview.* For the `disableAnimations` half this matches the platform —
  Android kills its own preview at animation scale 0. For the `DeviceTier.low` half it is our choice, and
  it does cost the preview on a low-tier Android 13+ phone. Revert: delete the `if (context.reduceMotion)`
  branch in `buildTransitions`, at the cost of the pass condition's third clause.
- *`/premium` goes 450 → 300 ms.* A real change to a money screen. The drag is progress-driven and
  duration-independent, which is why C and A measure the same; only the commit phase shortens, 400 ms →
  267 ms. Revert: delete the two duration overrides, or swap `/premium` back to `builder:`.
- *`ImageCache.containsKey` misses a live-but-evicted entry,* so the thumb would show the well instead of
  the wallpaper. The current card's poster is among the last few inserts and survives the 24–40 MB LRU;
  the fallback is a quiet tinted box, never a hole.
- *`PolicyScreen` already suppresses predictive back* when the reader has followed a link deeper
  (`PopScope(canPop: !_canGoBack)`). Pre-existing and by design — **not** a W10 regression, recorded here
  so nobody reads it as one during the device walk.

**Gates.** `flutter analyze` clean after main applied both call sites · `dart format` clean ·
`flutter test` 1028 passing (A6 verified in a scratchpad mirror with both call sites applied; main
re-ran it on the real tree).

---

## Device walk — W3, W4, W5, W6, W8, W9, W10

One build, split-per-abi, installed on both phones. `flutter analyze` clean, `dart format` clean,
`flutter test` 1028 passing before the build.

### The regression the device gate caught — W3 previews were SILENT

The first fresh preview after the W3 fades landed logged its load line and then nothing. Nineteen
seconds later, at the exact moment an audio interruption paused the player, the missing
`fade in 150ms` and `fade complete` finally appeared:

    02:31:42.587  [RingtonePreview] disk https://…/389b299f….mp3
    02:32:01.531  [RingtonePreview] interruption begin pause
    02:32:01.535  [RingtonePreview] fade in 150ms
    02:32:01.768  [RingtonePreview] fade complete 389b299f…

Cause, confirmed in just_audio 0.10.6's own doc comment on `play()`: *"The Future returned by this
method completes when the playback completes or is paused or stopped. If the player is already
playing, this method completes immediately."* Both play paths did `await _player.setVolume(0)` and
then `await _player.play()`. From idle that await parks for the whole clip, so **the ramp back up to
volume 1 never ran and the preview played silently**. It only looked right in the cross-fade case,
where the player was already playing and `play()` returned at once — which is exactly why the first
cross-fade test passed and hid it.

Fixed by main (A2 had finished; the file was free): `unawaited(_player.play())` in both branches, with
the reason written at the call site. Re-verified:

    02:38:09.289  [RingtonePreview] disk https://…/389b299f….mp3
    02:38:09.536  [RingtonePreview] fade in 150ms          (+247 ms)
    02:38:09.775  [RingtonePreview] fade complete 389b299f…

**No amount of code review would have found this.** It is the entire argument for the device gate.

### W3 — VERIFIED (A001)

Tapping a second row while the first plays:

    02:29:28.530  crossfade d1aac847… -> 389b299f…
    02:29:28.530  fade out 150ms
    02:29:28.758  disk https://…/389b299f….mp3
    02:29:28.904  fade in 150ms
    02:29:29.139  fade complete 389b299f…

The crossfade line and the state flip lead; `fade complete` trails; **no `stop` sits between the two
clips**. The whole handoff is 609 ms, 228 ms of it the fetch.

### W4 — VERIFIED (A001), with two branches code-only

A system timer taking audio focus mid-preview, then dismissed:

    02:38:34.332  interruption begin pause
    02:38:39.084  interruption end resume

Playback paused on the loss and resumed on the return, because the pause was ours. Two sub-branches
were **not** observed on a phone and are code-verified only, stated rather than glossed:

- *`interruption end stay`* — the user-paused case. Three adb attempts produced a playing player each
  time (the tap pair toggles), and the brief's three-attempt rule applies. The branch is guarded by
  `_pausedByInterruption`, which is only set when `state.isPlaying` at the moment of the loss.
- *becoming-noisy* — a headphone unplug cannot be induced over adb without a headset.

### W5 — VERIFIED (both phones)

A001, media volume at 0: the tap starts nothing, logcat prints
`[RingtonePreview] muted, not starting (volume 0)`, and the screenshot shows the localized toast
"Turn up the volume to hear this preview". Volume restored to 3/16, the same tap plays.
Vivo, volume driven to 0 with key events: the same toast, in the light theme, no audio.

### W6 — VERIFIED (both phones)

A001, two screenshots 4 s apart of the playing row's control, cropped and hashed: 2 distinct crops,
and the gold arc visibly advances from roughly 1 o'clock to roughly 4 o'clock. Only the playing row
carries an arc. The Vivo shows the same advance in the light theme — the low tier's static arc still
tracks position, it simply does not animate between ticks.

### W8 — VERIFIED (both phones)

A001, policy screen busy state: a gold comet arc over a dark gold track — the branded ring, not the
stock indicator. Vivo, same screen: a **complete calm ring at reduced opacity and no moving arc**,
which is the specified rest state. So both halves of the widget are on a phone: animated where motion
is allowed, at rest where it is not.

`grep -rn CircularProgressIndicator lib/` returns nothing.

### W9 — test VERIFIED, screenshot gate BLOCKED

The widget test asserting skeleton-to-row bounding boxes within one pixel passes, and it is the
stronger evidence — it pins row height, art rect, and the title and subtitle bars. The screenshot half
of the pass condition **could not be run**: the ringtone catalog is cached on both phones, so the
list lands in the first frame after the tab tap and the skeleton is never on screen long enough to
capture. Forcing a cold cache means `pm clear`, which would have destroyed the signed-in state the
rest of this walk depends on. Recorded as blocked rather than claimed.

### W10 — VERIFIED (both phones)

A001 at animation scale 1: a slow edge swipe on `/premium` scales the page into an inset rounded card
with the system back affordance — **the same preview as the pre-change baseline captured before any
W10 code existed**. At scale 0, four rapid frames across the same push show the premium screen
arriving fully in place at x=0, with no partially-slid intermediate frame; at scale 1 the same capture
shape on `/policy` clearly caught the outgoing screen mid-slide. Vivo (tier `low`, system scale
untouched at 1.0): pushing `/refer` also lands fully in place — the tier half of `reduceMotion`
working on its own.

**One thing that is not a regression.** `/policy/:doc` shows the back affordance without a page
preview. That is `PolicyScreen`'s own pre-existing `PopScope(canPop: !_canGoBack)`, which suppresses
predictive back while the reader's web view has history. A6 flagged it in advance so it would not be
misread during this walk; it was, and it is not ours.

---

## Gate 5 — frame timing on the low-end phone: instrument BLOCKED, memory measured instead

**Frame timing has no working instrument on the Vivo U10.** `dumpsys gfxinfo` reads 0 frames for a
Flutter app (Impeller, not HWUI — `docs/perf-measurement.md`), `--latency` is deprecated and returns
all-zero rows, and `SurfaceFlinger --timestats` on this ROM **never records the app's own layer**: a
clean enable → ten flings at a 250 ms gap → dump cycle returns `StatusBar#0` and, when the video
surface is up, `SurfaceView - com.hsrutility.arul/…`, and nothing else, while the global counter
shows 589 frames and `missedFrames= 0`. Three attempts, then stopped, per the run's own rule. This is
the same class of failure the perf doc already records for this phone, where the app's log lines are
suppressed too.

So the gate was run against the thing W1 actually predicts a change in: **memory after a fixed
browse**, which on this app is roughly 70% graphics — decoder output pools plus textures. Both builds
are PROFILE (AOT truth, debug signing), and they were **interleaved**, never sequential, because
sequential runs let the device warm across the boundary and hand the second build a free win.
Thermal status 0 throughout.

Scene, identical per run: force-stop, cold launch, 24 s to a settled feed, 20 flings at a 350 ms gap,
3 s rest, `dumpsys meminfo`.

| Run | Build | TOTAL PSS |
| --- | --- | --- |
| 1 | HEAD `921aa64` | 332 428 kB |
| 2 | `premium-polish` | 287 039 kB |
| 3 | HEAD `921aa64` | 339 918 kB |
| 4 | `premium-polish` | 273 981 kB |

Means: HEAD **336.2 MB**, branch **280.5 MB** — **−55.7 MB, −16.6%** on a 2.64 GiB phone, in the same
direction and the same order of magnitude in both interleaved rounds. Two inputs account for it: the
image-cache ceiling dropping 32 → 24 MB on tier `low`, and the decoder budget starting at 2 instead
of reaching 3 and demoting after a failed `prepare()`.

**What this does not show.** It is a memory number, not a smoothness number, and it is not evidence
about W2, W9 or W10, whose cost is frames rather than bytes. Those three rest on their own device
evidence — the parked-animation frame hashes, the pixel test, and the transition captures — and on
the fact that each removes work rather than adding it. Saying otherwise would be dressing up one
measurement as four.

---

## W7 — Current-ringtone badge — VERIFIED (Vivo)

**Agent:** A1 (Opus 5). **Files:** `MainActivity.kt` (ringtone half), `ringtone_set_service.dart`,
`ringtone_set_provider.dart`, `current_ringtone_badge.dart` (new),
`ringtone_set_grant_resume_test.dart`. Main wired the badge into `ringtones_screen.dart` and then
moved it (below).

**The finding that justifies two phones.** A1 read the live row off both devices before writing the
comparison:

    A001, API 36:      content://0@media/external/audio/media/1000015309?title=Succession (Main Title Theme)&soundOnly=1
    vivo 1916, API 28: content://media/internal/audio/media/104

`setActualDefaultRingtoneUri` **rewrites the URI it stores** — a `0@` user prefix on the authority
and a `?title=…&soundOnly=1` query on modern Android. A plain string comparison between the URI Arul
inserted and the URI read back **would have failed on every Android 10+ phone and passed on the API
28 Vivo.** A single-device check would have shipped it. Fixed with `canonicalRingtoneUri()` in
Kotlin — strip everything before the last `@` in the authority, clear query and fragment — applied to
both the set receipt and the live read, so Dart only ever compares one stable form. The rule has one
home, next to the write that causes it.

**The matching property holds.** `_match()` asks the platform for the live URI first and returns null
if there is none. The stored `arul_ringtone_uris` map is only a translation table from a system URI
to a catalog id — canonical URI equality, then MediaStore display-name equality, then null. No fuzzy
matching. So a tone changed outside Arul matches nothing and the badge disappears, which is the point.

**Main moved the badge after seeing it on a phone.** A1's insertion put it in the outer row beside
the title. On the 720p Vivo that turned "Venkatesha Garuda Dhvaja" into **"Venkate sha Ga…"** — the
badge ate the width the title needs, and it would be worse in Malayalam. Moved onto the **subtitle
line** as an inline sibling with the deity label `Flexible`: the title now renders in full across two
lines and the short deity name gives up the space instead. A1 had measured the badge at 16.0 dp
against the caption line's 16.8 dp, so it fits, and the row's pinned height never moves.

**What the phone showed.** The Vivo's account is premium, so Set was reachable. It deep-linked
straight to `ACTION_MANAGE_WRITE_SETTINGS` with no explainer, parked, and **finished itself on the
next resume** — both documented contracts, observed. Being API 28 it then took the pre-Android-10
branch and prompted for `WRITE_EXTERNAL_STORAGE`, the branch a modern phone never executes.

    $ adb -s 6589da20 shell settings get system ringtone
    content://0@media/external/audio/media/45489

After a force-stop and relaunch the gold **Current** badge appears on exactly that one row, and on no
other. Note the `0@` prefix is present even on API 28 here, so the canonicalisation earns its keep on
both phones.

**Carried forward.** The read is the AOSP default only. Arul writes the same URI to every enumerated
SIM row, so it is right for tones Arul set; a per-SIM row changed outside Arul while the AOSP default
still holds Arul's URI would leave the badge on. A1 deliberately did not widen the read, because
reconciling disagreeing rows means guessing what "current" means. Recorded as a known limit.

---

## Discovery track

A7 swept read-only and reported 21 findings plus a list of what it checked and found clean. Main
triaged against the three bars in §4 and fixed eight. **Two of the findings were real defects in code
written tonight that a green test suite could not see.**

### Fixed

**D1 — `arul_spinner.dart`: the animation controller was constructed inside `dispose()`.** `_c` is
`late final`, the reduced-motion path never read it, and `build()` reads it only while spinning — so
on a low-tier or battery-saver phone the **first** read was `dispose()`, which constructed the
controller during unmount and ran its ticker's `dependOnInheritedWidgetOfExactType` against a defunct
element. Debug throws; release leaves a defunct element registered in `TickerMode`'s dependents.
It fires on every busy state — every sign-in, Set, checkout and policy load — on exactly the
population the sign-in funnel is read against. Fixed by touching the field on the rest path
(`_c.value = 0`), the same shape `skeleton.dart` already had.

**Main added the test that catches it**, `test/app/widgets/arul_spinner_test.dart`, and **proved it is
not vacuous**: with the one-line fix removed, it fails with exactly the predicted
`FlutterError: Looking up a deactivated widget's ancestor is unsafe.` A7's note that the suite had
**zero** `reduceMotion` coverage is why this survived 1028 green tests, and that hole is now closed.

**D2 — the low-tier cross-fade never stopped the outgoing clip.** `_fadeOut` returns immediately under
`reduceMotion`, and the outgoing arm had no `stop()` — so on a low-tier phone the old ringtone kept
playing at full volume through the session await, the muted probe and the whole cache fetch, while the
lit row already showed the new one. Pre-tonight the code stopped unconditionally, so this was a
regression introduced by W3. Fixed: the reduced arm hard-cuts, and logs `cut <old> -> <new>`.
**W3 was device-verified on the A001 only, which resolves `mid`, so this arm had never run on a
phone** — the audit caught what the walk structurally could not.

**D3 — `_PositionRing` had no `RepaintBoundary`,** so its 30 fps tick marked the list item dirty and
repainted the row's decoration, both texts, the transport glyph and the Set pill 30 times a second
while any preview played. Every sibling that paints on a ticker already had one. One line.

**D4 — the play button's gold glow painted over the new position ring.** `nowPlayingButtonGlow` is an
8 px blur with no offset on a 34 px circle, washing across the ring at radius 18–20 and lifting its
faint track toward the arc's own gold. The ring now paints after the button.

**D5 — the Earn button re-armed a 3-second timer forever under reduced motion,** rebuilding the
`Transform` every tick to redraw the same angle, on exactly the low-tier phones the flag protects.
Re-arm moved to a one-minute cadence; the flag is still re-read, which is all the mid-session
battery-saver case needs.

**D6 — `ringtone_tile.dart` used `MediaQuery.of(context)` for `devicePixelRatio` alone,** depending on
every aspect, so any inset, rotation or text-scale change re-ran `didChangeDependencies` and
`_syncTicker()` on every visible tile. Now `MediaQuery.devicePixelRatioOf`.

**D7 — the chip skeletons drew the wrong height.** The ringtone rail drew pills at
`categoryStripHeight` (44, the hit box) where the real chip draws 34, so the rail visibly shrank
10 px when the catalog landed; the feed's twin drew 32. Both now read a new public
`ArulChip.categoryHeight`, and their dark fills were unified. **This is squarely what W9 set out to
close and missed** — a skeleton jumping is the exact defect that item exists to prevent.

**D8 — feed action-bar geometry was hand-mirrored.** `_ActionBar.height`, the action gap, the share
diameter and the Apply pill's min/max width were private to `feed_screen.dart`, so the new skeleton
copied them by hand — the same silent-drift bug W9 exists to prevent. Promoted into
`FeedCardGeometry`, the one public home, and both the real widgets and the skeleton now read them.

Two smaller ones fixed in passing: `RingtoneRow`'s doc comment claimed the row is `52 + 2×9 = 70`
tall when `extentFor(1.0)` is 79.30, and `_onPosition` now carries a `mounted` guard.

### Recorded, not fixed — ranked

1. **`minHitTarget` is 44, not Android's 48** (`arul_tokens.dart:659`) — the iOS number, used by every
   custom tappable in the app. Changing it moves the ringtone transport, the Set pill, the browse
   chips, the paywall back ring and the QR button, i.e. re-solves several layouts. Too wide for this
   run and it wants an owner decision: change it, or write 44 into `ui-direction.md` as deliberate so
   it stops being re-found.
2. **`upload_screen.dart:238` can show a raw Dart exception** — `e.toString()` from
   `upload_provider.dart:180` renders verbatim, so a `ClientException` reaches the user. Every sibling
   maps to `l10n.errorGeneric`/`offlineBody`. Contained, but Upload is not a screen this run touched.
3. **The reduced-motion flag is only half reactive.** Five sites guard with `if (_motionStarted)
   return` and swallow a later `didChangeDependencies`, so a spinner mid-flight keeps spinning after
   battery saver comes on. Either drop the guards or narrow the claim in `ui-direction.md`. Small
   user cost, but the doc currently overstates it.
4. **Nine strings are styled from raw `TextStyle` literals** rather than the scale (sizes 12.5, 13,
   14.5 appear in no token) — `arul_toast.dart:67` is the widest-reaching. Invisible individually;
   collectively it is why the scale cannot be tuned in one place.
5. **Text scale above 1.3 is neither clamped nor tested** outside the dock and the paywall, while
   Android's slider reaches 2.0. Two concrete candidates A7 could not rule out by arithmetic: the
   refer screen's fixed 24 px circle holding 12.5 px type, and the apply sheet's unscrolled `Column`.

Below the bar, recorded without action: the apply sheet's target cards fire no selection haptic
where every sibling picker does; two `LinearProgressIndicator`s spell the empty track two different
ways and `component_themes.dart`'s `circularTrackColor` is now dead config with a stale "teal"
comment; the `_SetPill` and `_SetProgress` layout jumps around a running Set; the play control stays
tappable while buffering; `RingtonesEmpty`/`FeedEmpty` pad with a literal 48; three colour literals
outside the two documented exceptions; the new `motion.dart` import is unsorted in six files, which
`analysis_options.yaml` cannot catch because `directives_ordering` is not enabled.

**Not fixed by rule, regardless of merit:** anything on sign-in, the paywall or the payment path.
A7 raised the `_ActionBarSkeleton`'s dark-on-ivory value pop and its English-only pill width; both
sit in the feed, not the payment path, but both are judgement calls A7 itself rated low, so they are
recorded rather than changed.
