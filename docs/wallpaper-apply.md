# Wallpaper apply — the OS hand-off

Read before touching `android/**/wallpaper/**` or `wallpaper_apply_provider.dart`.

**`android/**/wallpaper/**` is deliberately byte-identical to Pakiza's** (owner's call, modulo
identifiers). Keep the two in step when either changes, and do not re-add the in-place live swap Arul
used to carry.

## Static apply

**Hand the OS a bitmap ALREADY centre-cropped to the display aspect** (`ImageNormalizer
.cropToDisplayAspect`). With a wider bitmap and no hint the OS keeps the slack as parallax room
anchored at the LEFT edge and the launcher pans inside it, so every subject right of centre is cut.
Never go back to `visibleCropHint = null` on the raw file; verify by template-matching a launcher
screencap against the source.

The OEM zoom-crops UNIFORMLY past the minimum cover, so the static path does **not** distort —
measured on device. Stop re-deriving it.

## Live apply

- **EVERY live apply opens the system chooser — there is no in-place swap.** The user's "Set" tap is
  unobservable, so the notifier finishes IDLE and never claims success.
- The chooser previews THIS service, so its preview and the applied wallpaper share ONE renderer and
  one scaling mode: `SCALE_TO_FIT_WITH_CROPPING`, set on the player in `VideoRenderer.initialize()`
  and inherited by `swapVideo`. Without it a 9:16 source fills a 9:20 engine surface non-uniformly —
  roughly a quarter of vertical stretch on a tall panel. **Never derive it from display metrics:**
  the native window applies it to whatever surface the engine hands over, so it re-derives itself on
  every device and on rotation.
- **A wallpaper engine surface gets NO aspect handling for free.** Media3 documents
  `setVideoScalingMode` as `SurfaceView`-only; on an engine surface it works anyway, and
  `dumpsys SurfaceFlinger` still reports the pre-fix scale factors — only a screenshot correlated
  against both renders proves it.
- **ONE engine on ONE record.** The chooser commits both home and lock together, so they can never
  hold different live videos.
- Download the MP4 locally FIRST; release the feed decoder only AFTER the download completes, and
  await that before the native call.

## The static fallback — exactly two signals

Live apply degrades to the clip's OWN FIRST FRAME (`MediaMetadataRetriever` → centre-crop →
`setBitmap`; the OS stores a bitmap as PNG, so it is lossless) on **exactly two** signals, both
meaning live can never work on this device:

1. `hasSystemFeature("android.software.live_wallpaper")` is false, or
2. BOTH chooser `startActivity` calls throw.

**Never on anything else.** A missing or empty source, an IO failure or a prefs failure keeps its own
error code — those are retryable faults on a capable device. Never key it on `OemPolicy`: that list
exists for ROMs where the *setStream* lock write silently no-ops, which forces the decoded-bitmap
retry, and a manufacturer-keyed fallback trigger is the mass-misroute. Never use a `resolveActivity`
pre-flight either — query methods are package-visibility-filtered from API 30 and can report "no
handler" where the launch would succeed; the try/catch IS the probe. And never the `thumbs/` object:
it is 640-wide, `-q:v 3`.

The native result distinguishes the two outcomes (`{outcome: chooser}` vs
`{outcome: staticFallback, reason}`) so Dart never has to branch on the `unsupported` code, which
means different things in each native method. The fallback then takes STATIC semantics whole: flags
cleared, `confirmed: true` + `fallback: true`, its own toast.

**Watch `wallpaper_apply_live_fallback` against live `wallpaper_apply_attempt`** — the fallback is
for devices where live is impossible, so on mainstream hardware it must sit near zero. A rise means
capable devices are being routed to a still image.

## Surviving the recreate

Android 12+ recreates the activity on apply. `configChanges` must include `uiMode|colorMode`, and the
launch theme must be dark in both `values/` and `values-night/`. **Apply must never cold-restart the
app** (flutter/flutter#133722).

OEM live-wallpaper restrictions are caught and surface as a localized error, never a crash.
