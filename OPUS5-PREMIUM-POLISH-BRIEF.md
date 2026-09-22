# Premium polish — overnight run

Make Arul read as a premium app on both a flagship and a 2.7 GB phone. Ten specified work items,
plus a discovery track for what the specification misses. Everything needed is in this brief.

---

## 0. Run contract

**Start:** branch `overnight-2026-09-21`, HEAD `921aa64`, tree clean. Create `premium-polish` off
that HEAD and work there.

**End:** every item VERIFIED or BLOCKED with evidence, work uncommitted on `premium-polish`, one
report at `PREMIUM-POLISH-REPORT.md`. Do not commit. Do not build a release bundle.

**Nobody is watching this run.** There is no one to answer a question, so do not ask one. Where a
choice is open, take the option this brief names, or the lower-risk one; write the choice and its
reason into the ledger and keep going. The repo is fully committed and pushed, so a change that
turns out wrong costs a revert and nothing else — prefer acting to stalling.

**Scope.** W1–W10 in §3 are the mandate: do all ten, at the scope written. Beyond them, §4 opens a
discovery track — actively hunt for visual and technical inconsistencies and UI/UX defects this
brief does not name, and fix the ones that clear the bar in §4. Both tracks are in scope; neither
substitutes for the other. Do not narrow a specified item because discovery found something more
interesting, and do not widen a specified item to swallow a discovery finding — log it and handle it
on its own track.

**Narration.** One sentence before the first tool call saying what you are about to do. After that,
a brief update only when an item reaches VERIFIED or BLOCKED, or when direction changes. No
per-file narration. The ledger is the running record.

---

## 1. Subagents — hard caps

Set before launching anything:

```
CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2
CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1
```

Claude Code 2.1.224 is installed; these require 2.1.217 or later.

**Ten subagents for the whole run, at most two alive at once.** Seven are allocated in §2; three are
held for discovery fixes and rework. When the reserve is spent, do the remaining work yourself.

Delegate only the allocated tracks. Do not delegate work finishable in a handful of tool calls.
**Never spawn a subagent to verify, review or double-check your own work or another agent's** — the
verification in this run is device evidence (§5), collected by you.

**File ownership is exclusive.** Each agent's writable files are listed in §2; an agent must not
write a file owned by another. Unlisted files are yours.

Every subagent prompt carries, verbatim:

- the item's full spec from §3 and its pass condition from §5
- its exclusive file list
- the house constraints in §6
- `Report every problem you hit, including ones you are uncertain about or judge minor. Do not
  filter for importance — coverage is your job here, not triage. State what you changed, what you
  could not change, and why.`

Sonnet 5 subagents follow instructions literally and will not generalize from one example to the
rest. Spell out full scope explicitly: "every call site in this list, not only the first."

---

## 2. Allocation and order

| Agent | Model | Effort | Items | May write |
| --- | --- | --- | --- | --- |
| **main** | Opus 5 | xhigh | W1, W2, integration, discovery triage | native tier probe, `build_info.dart`, tier provider, `video_preload_controller.dart`, `main.dart`, anything unlisted |
| A1 | Opus 5 | xhigh | W7 | `MainActivity.kt` (ringtone half), `lib/features/ringtones/data/**`, `ringtone_set_provider.dart` |
| A2 | Sonnet 5 | xhigh | W3, W4, W5 | `ringtone_preview_provider.dart` only |
| A3 | Sonnet 5 | xhigh | W6 | `ringtone_tile.dart`, `ringtones_screen.dart` |
| A4 | Sonnet 5 | xhigh | W8 | `lib/app/widgets/arul_spinner.dart` (new), `button_content.dart`, `cta_button.dart`, `sign_in_screen.dart`, `policy_screen.dart`, `member_view.dart`, `paywall_view.dart`, `premium_screen.dart` |
| A5 | Sonnet 5 | xhigh | W9 | `skeleton.dart`, `sliding_skeleton.dart`, `feed_states.dart` |
| A6 | Opus 5 | xhigh | W10 | `lib/app/router.dart`, `apply_sheet.dart`, `arul_sheet.dart` |
| A7 | Opus 5 | xhigh | discovery sweep (§4) | nothing — read-only audit |
| A8–A10 | per finding | xhigh | discovery fixes, rework | scoped per assignment |

**Order.** W1 and W2 are foundations that later items read, so they land first and alone:

1. **main:** W1, then W2. Both verified before any agent launches.
2. **A2 + A4**
3. **A3 + A5**
4. **A1 + A6**
5. **A7** discovery sweep, while main walks integration
6. **A8–A10** on triaged discovery findings, two at a time
7. **main:** final integration walk and report

A2 and A3 both sit in the ringtones feature. The concurrency cap alone does not keep them apart —
sequence them as shown.

---

## 3. The ten work items

Read the routed doc before touching its area; the `[doc-sync]` hook names it, and the answer is
usually already there. This work touches `docs/ui-direction.md`, `docs/ringtones.md`,
`docs/perf-measurement.md`, `docs/video-feed.md` and `docs/edge-cases.md`.

### W1 — Device quality tiers, replacing the boolean *(main)*

`DeviceMemory.isLow` in `lib/core/config/build_info.dart:80-115` is a single flag — Android Go OR
under 4.5 GiB OR API 31 and below — and only the auth splash poster reads it. The native rule is
`MainActivity.kt:139`.

Replace it with a three-value ladder, `low` / `mid` / `high`, resolved once per process natively and
exposed through a Riverpod provider. Keep `isLow` as a derived getter (`tier == low`) so every
existing caller keeps working untouched.

Native inputs, in order: `ActivityManager.isLowRamDevice`, total RAM, `SDK_INT`, and `Build.SOC_MODEL`
where readable. Write the derivation as a documented table in the Kotlin, not as scattered
conditionals. **Fail open to `mid`** on any error — never to `low`, which would cripple a capable
phone over a failed probe.

What reads the tier:

- **Video preload depth** in `video_preload_controller.dart`. Low tier gets fewer decoders; the
  low-end device's SoC has two, and overcommitting it is the documented cause of its cold-feed jank.
- **Image cache ceiling** in `main.dart`.
- **Animation budget**, via W2.
- Nothing else without a ledger entry justifying it.

Do not branch layout on tier. Tier changes cost, never composition.

Stamp the resolved tier onto the analytics registered properties so any later metric can be split by
tier. Do not add a new event.

### W2 — Reduced motion, app-wide *(main)*

`MediaQuery.disableAnimations` is read in exactly one widget, `ringtone_tile.dart:135`. It is both an
accessibility signal and a battery-saver signal.

Add one `context.reduceMotion` accessor returning true when `disableAnimations` is set **or** the
tier is `low`. Route every animation in `lib/app/widgets/**` and `lib/features/**` through it.
Animations hold at their resting state rather than being removed, so nothing shifts position when
the flag flips.

Enumerate every `AnimationController`, `AnimatedSwitcher`, `Animated*` widget and `CustomPainter`
with a repaint listener in those trees. Fix each. List them in the ledger — the enumeration is part
of the deliverable, so a later reader can tell coverage from sampling.

### W3 — Preview audio fades *(A2)*

`toggle()` in `ringtone_preview_provider.dart` hard-starts and hard-stops. Add a 150 ms volume ramp
in and out, and cross-fade when a different row is tapped while one plays: the new clip ramps up as
the old ramps down. Never a silent gap, never a double-loud overlap.

The fade must not delay the visible state flip — the row shows as playing immediately and the audio
catches up. Skip the fade when `reduceMotion` is set; that flag covers audio transitions here too.

### W4 — Audio focus loss *(A2)*

The provider pauses on app lifecycle at `ringtone_preview_provider.dart:99` but never handles losing
focus to another app. An incoming call, another player starting, or a headphone unplug currently
leaves Arul playing over it.

Subscribe to the `AudioSession` interruption stream:

- transient loss with duck → duck
- transient loss → pause, resuming only if the user had not pressed pause themselves
- permanent loss → stop and release focus
- becoming-noisy (headphone unplug) → pause, never continue to the speaker

### W5 — Silent mode and zero volume *(A2)*

Media volume at zero, or the phone on silent, makes a preview look broken. Read the stream volume
before starting; if it is zero, do not start — surface it through the existing `ArulToast` with a
localized line asking the user to raise the volume. New ARB key in all six locales, English
authored, the rest translated.

### W6 — Playing-row position ring *(A3)*

Nothing on a playing row says where in the clip it is; the flame flicker is decorative. Add a thin
gold ring tracking elapsed position around the play control of the playing row only.

Drive it from the player's position stream resampled to at most 30 fps. Do not rebuild the row per
tick — the ring repaints in isolation. On low tier or under `reduceMotion`, show a static filled arc
at the current position instead of an animating ring. Use the existing gold token; no new colour.
Timing from the `Motion` vocabulary, no hand-written cubics.

### W7 — Current-ringtone badge *(A1)*

A set succeeds, a toast appears, and afterwards the app cannot say which tone is yours. Read the
current ringtone URI back from `Settings.System` natively and mark the matching row with a gold
badge that survives a restart.

Read the URI, never a locally cached id — the system is the source of truth and the user may have
changed the tone outside Arul. Match by URI, falling back to the stored filename. No match means no
badge, never a guess. Refresh on app resume.

`docs/ringtones.md` documents that these rows are OEM-private and must be enumerated rather than
guessed, and that a `SecurityException` on the read is a positive presence signal on API 31 and
above. The same rules govern this read.

### W8 — One branded spinner *(A4)*

Eleven bare `CircularProgressIndicator` sites — stock Android on the money screens. Build
`ArulSpinner` from the brand tokens and replace every one.

Audit each site: the determinate set-progress hairline in `ringtones_screen.dart` is correct as a
progress bar and stays one. This item replaces indeterminate spinners.

Sites: `button_content.dart:28`, `cta_button.dart:66`, `sign_in_screen.dart:425`,
`policy_screen.dart:353`, `member_view.dart:483`, `paywall_view.dart:257`, `paywall_view.dart:1348`,
`premium_screen.dart:1240`, `premium_screen.dart:1270`, and both in `ringtones_screen.dart`. Every
one of these, not a representative sample.

The spinner honours `reduceMotion` with a static ring at rest, never a frame frozen mid-sweep. The
premium screen keeps its own serif stack — the spinner takes the paywall tokens there.

### W9 — Content-shaped skeletons *(A5)*

Both existing skeletons are grey blocks, so content reflows when it lands. Reshape them to the
geometry of what they replace: a ringtone row skeleton carries the row's art square, title bar and
subtitle bar at the row's real metrics; a feed skeleton matches the card geometry that
`feed_card_geometry.dart` solves.

Nothing may move when real content arrives. Assert it in a widget test — the skeleton's and the
loaded row's bounding boxes match within a pixel.

### W10 — Route transitions and feed-to-sheet continuity *(A6)*

`lib/app/router.dart` pushes the premium screen, the policy screen and notification settings on the
default builder. Branch switches cross-fade; pushed routes do not.

Give the router a shared-axis transition built from the `Motion` tokens, applied to every pushed
route. Separately, carry the wallpaper's own image into the apply sheet so the object stays on
screen across the open, rather than the sheet rising over a fresh decode.

Predictive back must keep working — `theme.dart:62` sets `PredictiveBackPageTransitionsBuilder` and
Android 16 gestures depend on it. If a custom transition breaks predictive back, predictive back
wins: ship that route without the transition and record it in the ledger. Under `reduceMotion`, a
plain fade.

---

## 4. Discovery track

W1–W10 came from a partial pass over the app. They are a floor, not a ceiling. Sweep for what they
missed.

**A7 audits read-only and reports everything.** Its brief is coverage, not triage:

> Audit the app for visual and technical inconsistencies and UI/UX defects. Report every finding,
> including ones you are uncertain about or judge minor. Do not filter for importance or confidence
> — a separate triage step will do that. For each finding give: file and line, what is inconsistent
> or wrong, what it should be, your confidence, and an estimated user impact. It is better to
> surface a finding that later gets dropped than to silently omit a real one.

Ground the audit in evidence, not taste. Directions worth sweeping, not an exhaustive list:

- **Spacing and rhythm** — padding, gaps and insets that differ between screens with no reason;
  values hardcoded where a token exists.
- **Typography** — sizes, weights and tracking that drift from the type scale; strings that clip,
  overflow or wrap badly at 2× text scale or in the longest of the six locales.
- **Colour and token discipline** — literal colours where tokens exist; anything that reads wrong in
  the dark theme or the light one.
- **State coverage** — screens missing a loading, empty or error state, or showing a raw exception.
- **Interaction consistency** — touch targets under 48 dp; haptics missing where a sibling control
  fires one, or firing twice on one gesture; controls that do nothing while busy.
- **Localization** — untranslated strings, English leaking into a non-English build, text that
  breaks layout in Tamil, Telugu, Kannada, Malayalam or Hindi.
- **Technical** — wasted rebuilds, work on the build method, unbounded caches, listeners never
  disposed, images decoded above display size.

**Triage bar.** Main triages A7's findings and fixes those that meet all three:

1. A user could notice it, or it costs measurable frames or memory.
2. The fix is contained — no new dependency, no architectural change, no touching entitlement,
   payments, auth or the catalog.
3. It can be verified on a phone by the same gates as a specified item.

Findings that fail the bar are recorded in the report with the reason, not fixed. Anything touching
sign-in, the paywall or the payment path is recorded and **not** fixed, regardless of how good the
fix looks — those paths are verified against live money and are out of bounds for this run.

Discovery fixes go to A8–A10, two at a time, with the same exclusive-file discipline and the same
gates. Cap the discovery track at whatever the reserve agents can finish; leftover findings ship as
a ranked list in the report rather than as half-finished code.

---

## 5. Verification — external evidence only

You already check your own work. Do not add self-review passes on top of it. What this section adds
is evidence that cannot be produced by reasoning: what the phones actually do.

**Devices.** Two phones, a flagship (`00197654F006906`) and a 2.7 GB two-decoder low-tier device.
Both must be attached at preflight. If the low-end phone is missing, say so in the first line of the
report, run everything on the flagship, and mark every low-tier gate BLOCKED. Do not silently skip
it, and do not call an item VERIFIED on one phone.

Plain `adb` throughout. Never build or propose a UI-automation rig.

**Write the pass condition before the code.** For each item, the first ledger entry is one
observable sentence naming what will be seen on the phone if the item works — written before its
agent launches. An item is VERIFIED only when that pre-declared sentence is observed. A pass
condition edited after seeing the result is a failure, not a pass.

**Gates, in order, per item:**

1. `flutter analyze` clean, `dart format` clean, `flutter test` green.
2. Debug APK installs on both phones. **Build split-per-abi** — the phones carry versionCode 2040
   and refuse a flat debug APK as a downgrade. Read the whole install output; piping to `tail -1`
   hides the refusal.
3. Device walk: the pass condition observed on both phones, with the adb command and its output
   copied into the ledger.
4. Screenshot pulled and looked at for every visual item (W6, W7, W8, W9, W10, and any visual
   discovery fix). A release build needs an accessibility service enabled before a UI dump works.
5. Frame timing on the low-end phone for W1, W2, W9 and W10, same scene before and after.
   `docs/perf-measurement.md` has the method and the traps — read it before reaching for `gfxinfo`,
   which reads zero on Flutter.

**Iterating.** A failed gate means fix and re-run that gate. **Three attempts per item, then stop:**
mark it BLOCKED, write what failed and what was tried, revert that item's changes unless they stand
on their own, and move on. Never leave the branch failing analyze or test.

**Integration pass, once every item is in.** Install fresh on both phones, then walk: sign-in →
feed → apply a wallpaper → ringtones → preview → set → open the premium screen. Sign-in and the
premium screen are where a regression costs real money — a break in either is stop-and-revert, not a
BLOCKED note. Confirm the `arul_*` storage keys, the `arul://` scheme and the
`com.hsrutility.arul` package are untouched.

---

## 6. House constraints — non-negotiable

From `docs/ui-direction.md`, each one paid for on a real device:

- **No glassmorphism and no `BackdropFilter`**, including on the nav dock. It costs roughly 6–9 ms
  of raster per frame on mid-tier Android, and the video decoder needs that budget.
- **No `shimmer` package and no `ShaderMask`** — a mask forces `saveLayer()`, an offscreen pass every
  frame. Slide a gradient fill instead. Gradient before motion, motion before a mask, a mask never.
- **No `google_fonts`, no `font_awesome_flutter`.** Marcellus is bundled; bundling is the only way a
  typeface gets added.
- **No new dependency at all** without writing the justification in the ledger first.
- No glow on the active dock cell. Colour and geometry come from tokens, never literals.
- The drawn art in `ringtone_tile.dart` is artwork, not chrome — its grounds and its gold ink must
  not become tokens.
- The feed stays a vertical full-screen pager; the native video pipeline is built around it.
- Material 3 Expressive is not in Flutter stable. Do not chase it.

Repo rules:

- **Never commit**, and do not touch the pubspec version — its hook auto-commits with a full working
  tree add and would sweep this entire run into a commit.
- The secrets guard hook denies any git command naming a protected path. A denial is the hook
  working — unstage, never work around it.
- No changes under `workers/`. Nothing in this brief touches the backend.
- Generated files are tracked. Run `dart run build_runner build -d` after touching an annotated file
  and include the output.
- Every user-visible string is localized in all six locales: English authored, the rest translated.
- Never reference, mirror or diff against any other repository. This work is Arul's alone.
- `flutter test` is the only context where crash and performance reporting are skipped.

Design bar: nothing that reads as generic AI-app output — no purple gradients, no stock system-font
look, no component patterns lifted from a template. Arul's system is maroon `#7A1E33`, gold
`#D4A017`, ivory `#FAF5EC`, dark surface `#14090C`, CTA green `#1FA75A`, with Marcellus for display.
Anything new reads as part of that system or it does not ship.

---

## 7. Ledger and report

**Ledger** — `PREMIUM-POLISH-LEDGER.md`, written as the run goes, one section per item: pass
condition (written first), files changed, every gate that ran and its outcome, device output
verbatim, decisions taken and why, attempts used.

**Report** — `PREMIUM-POLISH-REPORT.md`, written last. Lead with the outcome: how many items
VERIFIED, how many BLOCKED, and whether both phones were attached. Then a short paragraph per item —
what changed, what the phones showed, what is left. Then the discovery findings: fixed, and ranked
but unfixed. Then the full list of modified files. Then anything needing a human decision.

Match the report's length to its substance. No filler sections, no restating this brief, no summary
of the summary. Three lines in, a reader should know whether the night worked.
