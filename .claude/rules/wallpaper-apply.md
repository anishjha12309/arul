---
description: The OS wallpaper hand-off — chooser always, and the exactly-two fallback signals.
paths:
  - "android/**/wallpaper/**"
  - "lib/features/wallpapers/providers/wallpaper_apply_provider.dart"
  - "lib/features/wallpapers/data/wallpaper_apply_service.dart"
---

**`android/**/wallpaper/**` is deliberately byte-identical to Pakiza's** (owner's call, modulo
identifiers). Keep the two in step when either changes, and never re-add the in-place live swap Arul
used to carry.

- **Static apply hands the OS a bitmap ALREADY centre-cropped to the display aspect.** With a wider
  bitmap and no hint the OS keeps the slack as parallax room anchored LEFT and the launcher pans
  inside it. Never go back to `visibleCropHint = null` on the raw file.
- **EVERY live apply opens the system chooser.** The user's "Set" tap is unobservable, so the
  notifier finishes IDLE and never claims success.
- **`SCALE_TO_FIT_WITH_CROPPING` is set on the player in `VideoRenderer.initialize()`** and inherited
  by `swapVideo`. Never derive it from display metrics — the native window applies it to whatever
  surface the engine hands over, so it re-derives itself per device and on rotation.
- **The static fallback fires on EXACTLY TWO signals:** no `android.software.live_wallpaper` feature,
  or both chooser `startActivity` calls throwing. Never on a missing source, an IO or prefs failure,
  `OemPolicy` (a manufacturer-keyed trigger is the mass-misroute), a `resolveActivity` pre-flight
  (package-visibility filtering lies; the try/catch IS the probe), or the `thumbs/` object.
- **Apply must never cold-restart the app.** `configChanges` includes `uiMode|colorMode`, and the
  launch theme is dark in both `values/` and `values-night/`.
- Release the feed decoder only AFTER the download completes, and await that before the native call.

Read [docs/wallpaper-apply.md](../../docs/wallpaper-apply.md) before changing any of it.
