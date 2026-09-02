# Ringtones — set, preview and row art

Read before touching `lib/features/ringtones/**` or the ringtone half of `MainActivity.kt`. Bulk
imports: [../tools/content-import/RINGTONES.md](../tools/content-import/RINGTONES.md). Feed order is
shared with wallpapers: [browse.md](browse.md).

## The two axes

**`category` is the browse axis and it is NOT the wallpaper set**: the five deities
(`perumal·murugan·sivan·amman·ayyappan`) plus **`others`** for tracks belonging to none of them
(Hanuman, Ganesha, gurus) — and **no `temples`**. Each tab derives its chips from its own catalog, so
the two lists differing is correct, not a bug.

**`deity` is a second, DISPLAY-ONLY axis** — row art and subtitle, never browse: no chip filters on
it, nothing orders by it. It is finer than `category`, which stays coarse (`perumal` alone spans
venkateswara/krishna/rama/narasimha). Resolution is deity → its CATEGORY's default → `fallback.webp`,
so a null or unknown deity degrades to the right family of god instead of breaking. `vishnu` and
`devi` are the generic defaults and must stay unattributed. **A new deity is an insert plus an app
release for its WebP, never a migration.**

**Classify from LYRICS, never file names** — a name-based first pass got 5 of 30 wrong.

## Draining the catalog

The tab renders nothing until the WHOLE catalog is drained (category filtering is client-side), so
every extra page is user-visible latency. `build-catalog` cuts ringtones at 200/page — one page for
any realistic catalog — the notifier drains pages in a 4-wide pool, never serially, and `AppShell`
warms the provider post-first-frame so the first tap lands on a ready list.

## Set

- Set needs `WRITE_SETTINGS`, and **ONE tone lands on EVERY SIM slot, never per-SIM.** Dual-SIM skins
  route each SIM's call through their own `Settings.System` row and never read the AOSP default, so
  `applyPerSimRingtones` writes the same URI to every ringtone row the device carries.
- **The row names are OEM-private, so ENUMERATE them off the provider (`discoverRingtoneKeys`), never
  guess.** Loose on the name (`contains("ringtone")`, so `oplus_…` variants are caught — but never
  the bare `ringtone`, which the framework owns), strict on the value (absent, or a URI; a `_set`
  marker or a vibrate flag is neither). Unenumerable skins fall back to probing known names, and on
  Android 12+ **a `SecurityException` on the READ is the POSITIVE presence signal** — the framework
  throws on a key it declares `@hide` and returns null for one it does not.
- **Wrap every write individually.** A best-effort extra must never fail a set that already
  succeeded. Verified device-side by diffing the whole table: same row count before and after,
  exactly two values changed.
- **`canWrite()` false → deep-link STRAIGHT to `ACTION_MANAGE_WRITE_SETTINGS`, state back to idle** —
  no in-app explainer sheet (owner's call). The request is then PARKED: on the first app resume it
  re-checks `canWrite()` and finishes the set by itself, or drops it if the grant was refused. It
  never re-opens Settings and never replays later. "Tap Set again" was the first cut and read on
  device as "granted it, nothing happened".
- The grant deep-link walks a FALLBACK CHAIN — per-package, then the bare app list, then app details.
  Some MIUI/ColorOS settings apps throw on the per-package form. A fully unresolvable chain is a
  silent no-op, accepted.
- **Below API 29 the tone is COPIED into the public Ringtones dir** and THAT path is registered on
  the EXTERNAL volume: the app-private path is unreadable by the ringtone player, and the `internal`
  volume never validates as a ringtone. Needs `WRITE_EXTERNAL_STORAGE` (capped `maxSdkVersion=28`),
  runtime-prompted at the first Set, never at launch. A modern phone alone never executes this
  branch — exercise both when touching Set.
- **Picker name = the CATALOG TITLE threaded through the channel**, never the downloaded filename;
  `mime` rides along, because some OEM scanners re-derive type from the extension and misindex a
  disagreeing row.
- **Stale-row cleanup must NEVER abort the set.** Pre-reinstall rows throw
  `RecoverableSecurityException`; skip them and let MediaStore uniquify, or re-setting any
  pre-reinstall tone breaks permanently.
- Set has a re-entrancy guard, same as apply and share: a double tap must not run two flows.

## Preview

**Preview is FREE** — the public `audio_key` straight from the CDN. Only Set gates, through
`/media/signed-url` with `kind: 'ringtone'`.

ONE shared `just_audio` player for ALL previews: starting a track stops the previous, so only one
decoder is ever held (the feed's video pool shares the device). Every now-playing affordance derives
from the ONE `currentId`; clearing it stops the audio, never just dims the row.

## Row art

Row art is a BUNDLED lossless WebP per **deity**, drawn over a ground still hashed from the ringtone
**id**, so a tile never re-rolls. The ground is what keeps dozens of one-deity tracks from being
dozens of identical tiles, so it must stay hashed and must stay at **≥8 distinct grounds** across a
category — every tile draws the SAME skeleton and permutes parameters, never a structural coin-flip.
Its grounds and ink are ARTWORK, not chrome, and must not become tokens
([ui-direction.md](ui-direction.md) §Drawn art).

`cover_key` is null on every row and nothing has ever been written under `ringtones/covers/…`.
**Never upload anything there:** it lands inside the swept `ringtones/` prefix with no row that can
reference it, so the canonical sweep deletes it — and a handful of objects sits under the deletion
floor, so the blast-radius failsafe will not save it.
