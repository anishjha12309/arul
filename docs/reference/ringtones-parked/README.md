# Ringtones — parked for the v1 production release (2026-07-29)

Ringtones ship **hidden** in v1: there is no ringtone audio in the bucket yet, so
the tab led to a "Ringtones are coming soon" empty state. Rather than ship a dead
tab, the *entry point* is commented out and everything behind it is left intact.

**Nothing was deleted, and nothing was gutted.** The whole ringtone tree still
compiles and is still type-checked by `flutter analyze` — it just has no route
into it, so Dart tree-shakes it out of the release build and the user can't reach
it. Un-parking is a one-file change.

---

## What actually changed

Two files. Search the repo for `RINGTONES-PARKED` to find every line to touch.

1. [lib/app/router.dart](../../../lib/app/router.dart) — the
   `StatefulShellRoute.indexedStack` (Wallpapers branch + Ringtones branch) is
   commented out and `/browse` is promoted to a plain top-level `GoRoute`.
2. [android/app/src/main/AndroidManifest.xml](../../../android/app/src/main/AndroidManifest.xml)
   — `WRITE_SETTINGS` is commented out. It exists **only** so `RingtoneManager`
   can set the device tone; it is a special-access permission that shows on the
   Play listing, so shipping it with no feature behind it invites review
   questions. It must come back in the same change that un-parks the route,
   otherwise "Set" fails the `Settings.System.canWrite` check on every device.

Untouched and still compiling:

- `lib/features/ringtones/**` — repository, providers, screen, set-service
- `lib/app/shell/app_shell.dart` — the shell + the floating dock (see below)
- `lib/data/models/ringtone.dart` (+ freezed/g.dart)
- every `ringtone*` / `tabRingtones` ARB key in all 6 locales
- the worker's `catalog/ringtones/…` scope and the `ringtones/` R2 sweep prefix

## Consequence for the UI

With one browse surface left, the floating dock had nothing to switch between, so
the shell around `/browse` is gone for now. The feed keeps its own `Scaffold` and
`SafeArea`, and its reel geometry is computed from available height (`_peek`,
`_cardInsetTop/Bottom` in `feed_screen.dart`) — no hardcoded dock offset — so the
reel simply reclaims the ~78 px the dock used to occupy. Nothing else moved.

Verified on device after the change, in both themes: the card grows taller and
the next-card peek sits clear at the bottom instead of being clipped by the
capsule. Everything else — header, chips, divider, the Apply/Share rail — is
unmoved.

The paywall needed no edit: `premiumHeadline` / `premiumBenefit*` were already
wallpaper-only ("Unlock every wallpaper"), and Settings never had a ringtone row.

`aapt2 dump permissions` on the built APK confirms the shipped permission set is
now `INTERNET`, `SET_WALLPAPER`, `VIBRATE` plus the SDK-contributed ones — no
`WRITE_SETTINGS`. Re-run that check after un-parking to confirm it came back.

---

## How to un-park (when ringtone audio exists)

1. In `lib/app/router.dart`: uncomment the `StatefulShellRoute.indexedStack`
   block, delete the temporary top-level `/browse` route, and restore the
   `shell/app_shell.dart` + `ringtones_screen.dart` imports.
2. In `AndroidManifest.xml`: uncomment `WRITE_SETTINGS`.
3. Drop the header note at the top of `lib/app/shell/app_shell.dart`.
4. `flutter analyze && flutter test`, then run on device and compare against the
   screenshots below — the dock must look pixel-identical. Check "Set" on a real
   ringtone too: that is what proves step 2 landed.

Nothing in the worker, the DB, the CMS or the ARB files needs to change.

---

## The floating dock — visual reference

Captured on a physical device (1080×2392, OnePlus/Galaga) at the commit that
parked ringtones, so the restored dock can be diffed against these.

| | Wallpapers active | Ringtones active |
| --- | --- | --- |
| **Light** | [01-current-state.png](01-current-state.png) | [02-light-ringtones-active.png](02-light-ringtones-active.png) |
| **Dark** | [03-dark-wallpapers-active.png](03-dark-wallpapers-active.png) | [04-dark-ringtones-active.png](04-dark-ringtones-active.png) |

What the reference shots establish:

- The dock is a **detached floating capsule** — 24 px side margins, 10 px above
  the gesture bar, 64 px tall, `ArulTokens.pillRadius`. Feed content runs
  full-bleed *behind* it (`Scaffold.extendBody: true`); in the light shot the
  next card's peek is visibly clipped by the capsule.
- A **solid pill fills exactly half** the capsule (`FractionallySizedBox`,
  `widthFactor: 0.5`) and glides between the halves with `AnimatedAlign`.
- **Light:** ivory capsule, maroon hairline rim, maroon pill, ivory label.
  **Dark:** near-black capsule, gold hairline rim, gold pill, dark-surface label
  — plus the gold diya-glow, clearly visible around the pill in the dark shots.
- The **label only renders on the active side** (`AnimatedSize`); the inactive
  side is a lone muted glyph — `Icons.wallpaper_outlined` / `Icons.music_note_outlined`.
- Icon 20 px, 7 px gap to the label, label in `ArulTokens.chipActive`.

### Paint recipe (as built)

| Token role | Light | Dark |
| --- | --- | --- |
| capsule | `ArulTokens.cardBgLight` | `ArulTokens.darkSheetSurface` |
| rim | `ArulTokens.maroonBorder18` | `ArulTokens.goldBorder35` |
| pill | `ArulTokens.maroon` | `ArulTokens.gold` |
| pill glow | `maroon @ 22%`, blur 16 | `gold @ 30%`, blur 16 |
| active label/icon | `ArulTokens.ivory` | `ArulTokens.darkSurface` |
| inactive glyph | `ArulTokens.lightSecondary` | `ArulTokens.darkMuted` |
| drop shadow | `darkSurface @ 55%`, blur 22, offset (0, 8) | same |

Motion is `ArulTokens.chromeSettleIn` / `ArulTokens.settleCurve` for **both** the
pill glide and the label reveal — deliberately one clock, so the pill never
outruns its text. Paint-only: no blur, no shaders (per `docs/ui-direction.md`).

### Behaviour the dock owned

`AppShell` was the referee for the two always-alive branches, and this logic must
come back with it:

- leaving **Wallpapers** → `videoPreloadController.releaseDecoders()` (budget SoCs
  have very few hardware decoders, and the hidden feed must not keep playing);
- returning to **Wallpapers** → `reclaimDecoders()` reconciles the pool onto the
  feed's current page;
- leaving **Ringtones** → `ringtonePreviewProvider.stop()` (idempotent — the
  screen's own route listener also stops it);
- tapping a tab fires `HapticFeedback.lightImpact()`; re-tapping the active tab
  pops that branch to its root.
