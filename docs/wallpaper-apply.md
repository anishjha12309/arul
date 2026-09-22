# Wallpaper apply — the OS hand-off

Read before touching `android/**/wallpaper/**` or `wallpaper_apply_provider.dart`.

**`android/**/wallpaper/**` is deliberately byte-identical to Pakiza's** (owner's call, modulo
identifiers). Keep the two in step when either changes, and do not re-add the in-place live swap Arul
used to carry.

**The download streams into `<name>.part` and renames only on success, and the `.part` is KEPT on
failure.** The rename is atomic, so the final name is never a truncated file the "exists and
non-empty" cache check would then accept forever. The surviving `.part` is what the next attempt
resumes from with `Range: bytes=N-` — a `200` means the server ignored the range, so truncate and
start over; a `416` means the part is already object-length and can never be a prefix, so drop it;
every other status keeps it, because an expired signed URL is a new grant away. Never re-add the
delete-on-failure. Same shape in `ringtone_set_service.dart` ([ringtones.md](ringtones.md) §Set).

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
- **A rebuilt decoder is a RESTARTED clip, and the user reads the restart as a stretch.** The engine
  frees its decoder whenever the wallpaper goes invisible (right for the budget), so every return to
  the home screen rebuilt the player at position 0 and replayed the clip's opening; generated clips
  often open on a wide shot and zoom in, which looked like the wallpaper "stretching in, then out"
  on every app switch and once on first apply (the home engine started at 0 while the chooser's
  preview engine was mid-clip). `VideoRenderer` keeps the last position per ADOPTED SOURCE path,
  process-wide, and passes it as `setMediaItem(item, startMs)` on every rebuild — the key is the
  source, not the engine's private copy, so the preview→home hand-off continues too. Verify with a
  10 fps screen recording across a HOME press: the first home frame must match the clip's phase,
  not its opening shot. The codec's scaling mode was NOT the cause: the recorded frames were
  aspect-true. Passing `android._video-scaling` in the configure `MediaFormat` is dead weight —
  MediaCodec overwrites it and `CCodec` still logs `= 1`. Start the renderer from the first non-zero
  `onSurfaceChanged`, never from `onSurfaceCreated`: only the former carries the engine's geometry.
- **A wallpaper engine surface gets NO aspect handling for free.** Media3 documents
  `setVideoScalingMode` as `SurfaceView`-only; on an engine surface it works anyway, and
  `dumpsys SurfaceFlinger` still reports the pre-fix scale factors — only a screenshot correlated
  against both renders proves it.
- **The player takes the raw `Surface`, never the `SurfaceHolder`, and only from main.** Media3
  documents `setVideoSurfaceHolder` as requiring the holder's callbacks on the player's application
  looper, and a wallpaper engine cannot promise that: OEM Android 12 builds fire `surfaceChanged` on
  the service's own thread, so ExoPlayer's own holder callback hit `verifyApplicationThread` and
  killed the process ("Unable to stop service", the user dropped to the default wallpaper). Pinning
  the looper to main was not enough on its own. `setVideoSurface(holder.surface)` registers no
  Media3 callback; the engine's callbacks reach the player through `onMain`, and an off-main
  `onSurfaceDestroyed` waits (bounded) for `clearVideoSurface` before the framework frees the Surface.
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

**Decode the fallback bitmap BOUNDED** — `inJustDecodeBounds` first, then a power-of-two
`inSampleSize` against 2× screen width (the parallax room the normalizer may emit) — or Play's vitals
lint flags the unbounded `decodeFile` and an un-normalized source is decoded whole on a budget phone.
`ARGB_8888` stays: a 565 re-decode bands the q90 JPEG's gradients.

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
