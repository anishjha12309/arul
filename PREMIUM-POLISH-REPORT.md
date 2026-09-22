# Premium polish — report

**Both phones were attached for the whole run.** Ten specified items: **nine VERIFIED on device, one
(W9) verified by test with its screenshot gate BLOCKED.** Eight discovery fixes landed on top. Nothing
is committed; everything sits uncommitted on `premium-polish`, branched from `921aa64`.

The run's value is not the ten items. It is the **three defects the device gate and the audit caught
in code written tonight**, each of which passed `flutter analyze`, passed 1028 tests, and would have
shipped:

1. **Every fresh ringtone preview played silently.** W3's fades did `await _player.setVolume(0)` then
   `await _player.play()` — and just_audio's own doc says that future does not complete until playback
   *ends*. From idle the ramp back to volume 1 never ran. It looked correct in the cross-fade case,
   where the player is already playing and `play()` returns at once, which is exactly why the first
   test passed and hid it. Found because the fade-in line appeared in logcat **19 seconds late**, at
   the moment an interruption paused the player.
2. **The branded spinner constructed its animation controller inside `dispose()`** on every
   reduced-motion phone — a ticker built against a defunct element, on every sign-in, Set, checkout and
   policy load, for exactly the population the sign-in funnel is read against.
3. **On a low-tier phone the old ringtone never stopped** when you tapped a new one: it kept playing at
   full volume through the whole download while the UI showed the new row. W3 was device-verified on
   the A001, which resolves `mid`, so that arm had never run on a phone.

The first was caught by the phone, the second and third by the read-only audit. Both gates earned
their place.

---

## The ten items

**W1 — Device quality tiers · VERIFIED.** A three-rung ladder (`low`/`mid`/`high`) resolved once
natively from a documented table, failing open to `mid`, with `DeviceMemory.isLow` reduced to
`tier == low` so every existing caller is untouched. It drives the feed's decoder-budget seed, the
image-cache ceiling and W2's animation budget, and stamps `device_tier` as a registered analytics
property with no new event. The phones: the Vivo holds **2** decoders from the first swipe where HEAD
holds 3, and shows the still poster where the A001 shows the looping video.

*The pass condition failed as written and is recorded rather than edited.* It predicted `high` on the
"flagship" A001. The A001 is a MediaTek **MT6878** — the exact SoC `docs/perf-measurement.md` measured
the 48 MB image-cache regression on — so `mid` is correct and `high` would have been the bug. The
sentence was wrong about the hardware, not the code. **Consequence: no attached phone exercises the
`high` rung,** so its 40 MB ceiling is reviewed and unit-covered but not device-verified.

**W2 — Reduced motion, app-wide · VERIFIED.** One `context.reduceMotion` accessor, true on
`MediaQuery.disableAnimations` (accessibility *and* battery saver) or tier `low`. Fourteen animation
sites enumerated and routed through it, each **holding at its resting state** rather than being
removed. Proven by hashing 14 frames of the Earn button's 3-second wiggle: 3 distinct crops at
animation scale 1, one crop at scale 0, one crop on the Vivo with the system scale untouched — so the
two signals work independently, and the parked hash equals the *at-rest* hash rather than a frozen
mid-swing frame.

**W3 — Preview fades · VERIFIED.** A 150 ms ramp in and out with a generation guard, and a cross-fade
that overlaps the outgoing ramp with the incoming fetch. One shared player means one decoder, so a
true two-clip overlap was never available; the handoff carries no `stop()` between clips, which is
what the item asked for. Logcat shows crossfade → fade out → fetch → fade in → fade complete in 609 ms.
Carries the silent-preview fix above.

**W4 — Audio focus · VERIFIED.** Duck, pause-and-resume-only-if-we-paused, permanent-loss stop, and
becoming-noisy. A system timer taking focus mid-preview gives `interruption begin pause` then
`interruption end resume`. Two branches are **code-verified only and said so**: the `stay` case, after
three adb attempts under the run's own three-attempt rule, and headphone-unplug, which cannot be
induced over adb without a headset.

**W5 — Silent device · VERIFIED both phones.** Reads `STREAM_MUSIC` before starting; at zero it does
not start and shows the localized line. Ringer mode is deliberately excluded — silent gates the
ringtone stream, not music, and gating on it would block a preview the user could actually hear.

**W6 — Position ring · VERIFIED both phones.** A thin gold arc around the playing row's control only,
resampled to 30 fps, advancing from ~1 o'clock to ~4 o'clock over four seconds on both phones.

**W7 — Current-ringtone badge · VERIFIED.** The one place two phones were structurally necessary:
`setActualDefaultRingtoneUri` **rewrites the URI it stores** (a `0@` user prefix, a
`?title=…&soundOnly=1` query), so a plain string compare would have failed on every Android 10+ phone
and **passed on the API 28 Vivo**. Canonicalised in Kotlin next to the write that causes it. The badge
reads the system, never a cached id, so a tone changed outside Arul makes it disappear.

*Main moved it after seeing it.* Beside the title it turned "Venkatesha Garuda Dhvaja" into
"Venkate sha Ga…" on a 720p phone. It now sits on the subtitle line, where the short deity name gives
up the space instead and the title renders in full.

**W8 — One branded spinner · VERIFIED both phones.** Eleven stock indicators replaced;
`grep CircularProgressIndicator lib/` is empty. A comet arc over a faint track, drawn as a gradient
*fill* on the arc's own `Paint` — never `ShaderMask`. On the Vivo it renders the specified rest state:
a complete calm ring, not a frozen sweep. Carries the `dispose()` fix above.

**W9 — Content-shaped skeletons · test VERIFIED, screenshot gate BLOCKED.** The item found a shipped
bug the brief had not: the ringtone skeleton was **3.3 px shorter than the real row**, because it sized
to its art instead of reading `RingtoneRow.extentFor` — so every ringtone list jumped a little when the
first page landed. Fixed at the source, with a widget test pinning skeleton-to-row boxes within one
pixel. That test caught a real 13.25 px error during authoring and was fixed by correcting the
assertion, never by loosening the tolerance.

**The screenshot half could not be run.** The ringtone catalog is cached on both phones, so the list
lands in the first frame after the tab tap and the skeleton is never on screen long enough to capture.
Forcing a cold cache means `pm clear`, which would destroy the signed-in state the rest of the walk
depends on. Recorded as blocked rather than claimed.

**W10 — Route transitions and sheet continuity · VERIFIED both phones.** A6 settled the predictive-back
question by **measurement, not reasoning** — nine probes against the real `flutter/backgesture` channel
— and found the spec's premise wrong: the push was already a shared axis
(`FadeForwardsPageTransitionsBuilder` is shared-axis X), so the only missing clause was the
reduced-motion fade. It also measured that `CustomTransitionPage` still breaks predictive back *and*
silently freezes the route below — a second regression invisible in a screenshot.

What shipped is `ArulPushPage` over `MaterialRouteTransitionMixin`: `Motion.enter` timing, a plain fade
under reduced motion, and a delegate holding the shell still. On the phone, `/premium`'s back-gesture
preview is **the same inset card as the pre-change baseline**; at scale 0 the page arrives with no
mid-slide frame. The apply sheet carries the card's own cached poster — the same `ImageProvider`, since
asking for a smaller decode would produce a different cache key and miss.

---

## Discovery track

A7 audited read-only and returned 21 findings plus a list of what it checked and found clean. Eight
were fixed; the two most serious are in the opening of this report. The others: the position ring had
no `RepaintBoundary` and was repainting the whole row 30×/s; the play button's glow painted over the
ring; the Earn button re-armed a 3-second timer forever under reduced motion; a `MediaQuery.of` was
over-subscribing across every ringtone tile; and **both chip skeletons drew the wrong height** — the
ringtone rail at 44 (the hit box) against a real chip of 34, so the rail visibly shrank when the
catalog landed. That last one is squarely what W9 set out to close and missed.

Main also promoted four hand-mirrored geometry constants into `FeedCardGeometry`, closing the
silent-drift hole W9 could only half-close from inside its own files.

**The audit's most useful observation was about the tests, not the code:** the suite had *zero*
`reduceMotion` coverage, which is why the spinner defect survived 1028 green tests. That hole is now
closed by `test/app/widgets/arul_spinner_test.dart`, and the test was **proved non-vacuous** — with the
one-line fix removed it fails with exactly the predicted
`Looking up a deactivated widget's ancestor is unsafe`.

Five findings are recorded and ranked but **not** fixed, in `PREMIUM-POLISH-LEDGER.md` §Discovery.
The one wanting an owner decision: `minHitTarget` is **44**, the iOS number, not Android's 48 — every
custom tappable in the app is built from it, so changing it re-solves several layouts. Either change
it or write 44 into `ui-direction.md` as deliberate, so it stops being re-found.

---

## Gates

`flutter analyze` clean · `dart format` clean on every file this run authored · `flutter test`
**1032 passing** · split-per-abi debug
APKs installed on both phones · integration walk green end to end: sign-in → feed → apply (gate →
`/premium`) → ringtones → preview → set → premium screen, with no exception in logcat. The `arul_*`
storage keys, the `arul://` scheme and `com.hsrutility.arul` are untouched.

*On `dart format`:* six files in the tree fail a repo-wide `--set-exit-if-changed` under this
machine's formatter. **Five are untouched by this run** (`catalog_providers.dart` and four
`test/features/wallpapers|ringtones` files) and were left alone so the modified-file list means
something. The sixth, `test/l10n/support/arb_index.g.dart`, is generated by
`tools/l10n/gen_arb_index.dart` and its committed version at `921aa64` was already unformatted — a
generator quirk, not this run's, and formatting it by hand would be undone by the next generator run.

**Gate 5, frame timing, has no working instrument on the low-end phone.** `gfxinfo` reads 0 frames for
a Flutter app, `--latency` is deprecated, and SurfaceFlinger `--timestats` on this ROM never records
the app's own layer — three attempts, then stopped. So the gate was run against the thing W1 actually
predicts a change in, **interleaved** across two rounds on profile builds:

| | HEAD `921aa64` | `premium-polish` |
| --- | --- | --- |
| round 1 | 332 MB | 287 MB |
| round 2 | 340 MB | 274 MB |

**−55.7 MB, −16.6%** of PSS on a 2.64 GiB phone. That is a memory number, not a smoothness number, and
it is not evidence about W2, W9 or W10 — those rest on their own device evidence.

---

## Modified files

**65 files**, excluding this report, the ledger and the brief. Thirteen of the 65 are generated and
tracked: six `*.g.dart` and the seven `app_localizations*.dart`. Two are new source
(`lib/app/widgets/arul_spinner.dart`, `lib/features/ringtones/presentation/current_ringtone_badge.dart`)
and two are new tests (`test/app/widgets/arul_spinner_test.dart`,
`test/features/ringtones/skeleton_geometry_test.dart`). The full list is in the ledger; the shape is
`lib/app/**` (theme, widgets, router, shell), `lib/features/{ringtones,wallpapers,premium,auth,legal}/**`,
the ringtone half of `MainActivity.kt`, all six ARBs plus their generated localizations, and
`docs/ui-direction.md` + `.claude/rules/theming.md` for the two new app-wide rules.

Two files were touched for reasons outside this run's scope and are called out so they are not
mistaken for item work: `test/l10n/support/registry.dart` (two stub signatures and one call site that
API changes forced) and `test/features/premium/paywall_view_test.dart` (one selector, because it was
the only place in the suite asserting on the stock indicator type).

---

## Needing a human decision

1. **`minHitTarget = 44` vs Android's 48.** As above — a change, or a documented deliberate exception.
2. **`/premium`'s push is now 300 ms, not the SDK's 450.** A real change to a money screen. The drag is
   progress-driven and measured identical to the baseline; only the back-gesture commit shortens, 400 ms
   → 267 ms. The revert is two lines and is written in the ledger.
3. **Reduced motion costs the back-gesture preview.** For the `disableAnimations` half that matches the
   platform. For the `DeviceTier.low` half it is our choice, and it costs the preview on a low-tier
   Android 13+ phone. One line to revert, at the cost of W10's third clause.
4. **W9's screenshot gate is unrun** (above). If it matters, it needs a phone with the ringtone cache
   cleared and a fresh sign-in.
5. **The `high` tier is unexercised** by either phone, so its 40 MB image-cache ceiling has no device
   evidence.
6. **A3 never delivered a report.** Its work (W6, the two remaining spinner sites, the muted toast) is
   in the tree, analyze-clean, test-green and device-verified by main, but there is no author's account
   of it — so its decisions and any caveats it hit are not recorded anywhere.
