---
description: Ringtone categories, deity display axis, Set contract.
paths:
  - "lib/features/ringtones/**"
---

- **Ringtone categories are NOT the wallpaper ones**: the five deities plus **`others`**, and **no
  `temples`**. Each tab derives its chips from its own catalog.
- **`deity` is a second, DISPLAY-ONLY axis** — row art and subtitle, never browse. Resolution is
  deity → its category's default → `fallback.webp`, so a null degrades to the right family of god.
  A new deity is an insert plus an app release for its WebP, never a migration. **Classify from
  LYRICS, never file names.**
- **Set writes ONE tone to EVERY SIM ringtone row.** Dual-SIM skins never read the AOSP default. The
  row names are OEM-private, so ENUMERATE them off the provider rather than guessing — loose on the
  name, strict on the value — and on Android 12+ a `SecurityException` on the READ is the POSITIVE
  presence signal. Wrap every write individually: a best-effort extra must never fail a set that
  already succeeded.
- **`canWrite()` false → straight to `ACTION_MANAGE_WRITE_SETTINGS`, no explainer sheet**, and PARK
  the request so the next app resume finishes it by itself. Never re-open Settings, never replay
  later.
- **Below API 29 the tone is copied to the public Ringtones dir** and registered on the EXTERNAL
  volume; a modern phone never executes that branch, so exercise both when touching Set.
- Picker name is the CATALOG TITLE. Stale-row cleanup must never abort the set.
- **Preview is FREE** (public `audio_key` from the CDN); only Set gates. ONE shared preview player,
  and every now-playing affordance derives from the ONE `currentId`.
- Row art is BUNDLED per deity over an id-hashed ground, ≥8 grounds per category. `cover_key` stays
  null — **never upload under `ringtones/covers/`**; the sweep deletes it.

Read [docs/ringtones.md](../../docs/ringtones.md) before changing any of it.
