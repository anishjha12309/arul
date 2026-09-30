# Media Conventions

**No server-side transcoding — ever.** Transcode locally, then upload through the unified CMS or, for
bulk jobs, direct to R2 plus one DB transaction (`tools/content-import/`, content-ops skill). Content
kinds: wallpapers (static + live) and ringtones (audio only).

## R2 keys and formats (bucket `south-indian-wallpapers`)

Everything is **category-partitioned**: `wallpapers/<category>/<uuid>.{jpg|mp4}` across the six
wallpaper categories. Some older objects use a 16-hex stem instead of a UUID — `full_key` is
arbitrary text, so both are fine and old keys stay as they are.

**Never partition by static-vs-live (a `posters/` vs `full/` split).** Category is the browse axis, and
approving a user submission copies the object into that category's prefix. The sweep prefix stays
`wallpapers/`, so it covers every category folder.

| Type | R2 key | Input | Output | Max |
|------|--------|-------|--------|-----|
| Wallpaper (static) | wallpapers/&lt;category&gt;/{uuid}.jpg | JPG/PNG/WEBP | 1080×1920 JPG | 10 MB |
| Wallpaper (live) | wallpapers/&lt;category&gt;/{uuid}.mp4 | MP4/MOV | **1024×1824** H.264 MP4 faststart, no audio, **≤10 s** | **15 MB** |
| Ringtone (audio) | ringtones/&lt;category&gt;/{uuid}.mp3 | MP3/M4A/AAC | MP3 (libmp3lame), ≤40 s recommended | 15 MB |

**Those "Max" figures are the IMPORT PIPELINE's, not the Worker's.** The static 10 MB cap is enforced
on both paths, but the Worker's server-side ceiling for `video/mp4` is far higher — so a
user-submitted MP4 well over 15 MB passes server-side validation. Only `verify.mjs` enforces the
bulk-import figure.

**There is no ringtone cover role** — row art is bundled in-app ([ringtones.md](ringtones.md) §Row art).
The canonical sweep still reads `cover_key` (null on every row) into its keep-set; leave that as it is.

## THE video rule: width % 128 == 0, height % 32 == 0, inside the 1088×1920 hw-decoder cap

Verified on-device across two budget SoC families. Budget hardware decoders fit only about two
concurrent 1080p sessions, so extra feed players SILENTLY fall back to the software decoder; on that
path gralloc pads the buffer width (128 px Qualcomm, 64 px MTK) and Flutter's ImageReader samples the
full padded buffer while ignoring the crop rect (flutter/flutter#174026) → a zeroed-YUV **green edge
strip**.

Dead ends already tried, do not retry: 16-align FAILED · 64-align FAILED on Qualcomm · wider than
1088 FAILED (exceeds vendor caps → permanent software decode) · Skia opt-out FAILED (ImageReader-backed
on both renderers).

**Canonical: 1024 = 128×8, 1824 = 32×57, ≈9:16.** Static posters stay 1080×1920 — images never pass
through a video decoder, so do not "align" them.

## ffmpeg recipes

**Sources usually arrive at 720×1280, so most clips are UPSCALED to 1024 wide** — and upscaling
cannot add detail, so use `lanczos` plus a light `unsharp` and a lower CRF than a native-res master
wants (a native-res CRF lays mush on an already-soft frame). A source at or above the target is
DOWNSCALING — token sharpen only, more just adds halos. **The geometry cannot stretch:**
`scale(…increase)` + `crop` is a COVER fit — on a 9:16 source it trims a couple of pixels
of width and no height. Stretched output? Suspect the renderer.

**Static wallpaper** (`upscale` chain shown; drop `unsharp` when the source is ≥1080 wide):
```bash
ffmpeg -i input.jpg -vf "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1920,unsharp=5:5:0.5:3:3:0.0" -q:v 2 output/{uuid}.jpg
```

**Live wallpaper** (H.264 faststart, 128/32-aligned). Upscaled → `unsharp=5:5:0.6:3:3:0.3` + `-crf 21`;
native or downscaled → `unsharp=3:3:0.3:3:3:0.0` + `-crf 20`:
```bash
ffmpeg -i input.mov -t 10 -vf "scale=1024:1824:force_original_aspect_ratio=increase:flags=lanczos:out_range=tv,crop=1024:1824,unsharp=5:5:0.6:3:3:0.3,setsar=1,format=yuv420p" \
  -c:v libx264 -profile:v high -preset slow -crf 21 -x264-params aq-mode=3 -an -movflags +faststart output/{uuid}.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt output/{uuid}.mp4  # MUST print 1024 / 1824 / yuv420p
```
**`out_range=tv` and the trailing `format=yuv420p` are load-bearing**: without them ffmpeg emits
full-range `yuvj420p`, which `verify.mjs` rejects — repairing that batch is what `fix.mjs` exists for
(its encoder MUST stay in lockstep with `normalize.mjs`). `setsar=1` stops a non-square SAR surviving
the crop. `aq-mode=3` spends bits on flat gradients, which is where smoke and sky band.

**15 MB is a hard ceiling, quality-first underneath it** (owner's call): `normalize.mjs` re-encodes
ONLY an overshooting clip, with a `-maxrate` sized from its own duration, so one heavy clip is capped
instead of every clip being pre-emptively starved. Bulk statics go through `sharp` (lanczos3 plus
sharpen when upscaling) — tuned to match this recipe, not byte-identical to it.

**Paywall clips** (`onboarding/<lang>.mp4`, `onboarding/return/<lang>.mp4` — the only AUDIBLE
media): 16:9 at 1024×576 (both dimensions on the video rule), and **level every cut to −14 LUFS** —
dubs arrive near −14 while an English master arrived at −6 and clipping, so switching language
jumped the volume. Two-pass `loudnorm` (measure, then feed `measured_*` back with `linear=true`),
then a limiter:
```bash
ffmpeg -i in.mp4 -map 0:v:0 -map 0:a:0 -sn -map_metadata -1   -vf "fps=25,scale=1024:576:flags=lanczos:out_range=tv,unsharp=3:3:0.3:3:3:0.0,setsar=1,format=yuv420p"   -c:v libx264 -profile:v high -preset slow -crf 25 -maxrate 700k -bufsize 1400k -g 50   -af "loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=…:measured_TP=…:measured_LRA=…:measured_thresh=…:offset=…:linear=true,aresample=48000,alimiter=limit=0.84:level=false"   -c:a aac -b:a 64k -ar 48000 -ac 2 -movflags +faststart out/<lang>.mp4
```
Dubs ship with a `mov_text` subtitle track — `-sn` drops it. A new cut or re-cut is an upload plus a
`feature_flags.<onboarding|return>_video` edit (`langs`, `version` → `?v=`), never a release.

**No launch clip is bundled (owner).** 2 MB read visibly soft on the wall's zoomed crop. Every wall clip
downloads after Google's surface: the catalog row's file, or a wall-only cut at `launch/<deity>_vN.mp4`
(`RegionalPoster.launchClipKey`) when the row is heavy. Murugan's row is 9.5 MB (12.6 Mbps), so its
cut is ~3 MB: 1024×1824, the source's last 15 frames crossfaded into its start (0.625 s) so the loop
has no cut, two-pass `-b:v 4400k -maxrate 6600k -bufsize 8800k`, H.264 High@4.0, faststart. Upload with
`node node_modules/wrangler/bin/wrangler.js r2 object put south-indian-wallpapers/launch/<name> --file …
--content-type video/mp4 --cache-control "public, max-age=31536000, immutable" --remote` from `workers/`;
a re-cut is a new `_vN` key plus a release. No sweep judges `launch/`.

A launch poster is frame 0 of the clip the wall plays, at 1024×1824 lossy WebP q80, ≤256 KB
(`launch_art_test.dart`) — the clip's own frame, so the crossfade lands pixel-for-pixel. Encode with Pillow, not ffmpeg's `libwebp` (its YUV path scored
lower SSIM at a larger file):
```bash
ffmpeg -i <clip>.mp4 -frames:v 1 -pix_fmt rgb24 f0.png
python -c "from PIL import Image; Image.open('f0.png').convert('RGB').save('assets/images/regional/<deity>.webp', 'WEBP', quality=80, method=6)"
```

**Ringtone audio:**
```bash
ffmpeg -i in.m4a -c:a libmp3lame -q:a 4 out/<uuid>.mp3
```

## Checks before upload / import
- Dimensions exact: static 1080×1920 · live 1024×1824. The LIVE rule is gated server-side, so no
  off-spec clip can land — **but a STATIC upload is not**: the CMS warns and lets the operator
  confirm past it, and the Worker checks only a wide range, which is how two 800px-wide wallpapers
  reached prod published.
- Extension matches mime (mp4→video/mp4, jpg→image/jpeg); size within the caps above.
- Live MP4 `pix_fmt` is limited-range `yuv420p` — `yuvj420p` is a hard import failure.
- Live MP4: faststart (moov before mdat) · **no audio stream** · first frame representative, not
  black — the card holds the `thumbs/` poster until the texture reveals, so a black first frame does
  not read as "loading", it reads as a good image being replaced by a broken one.
- **≤10 s, and `normalize.mjs` auto-trims to the first 10 s** (owner's call). **The cut is BLIND**: it takes
  the leading window, so it can land mid-motion and will not respect a loop point. It flags `trimmed:<n>s` —
  review those before publishing. `verify.mjs` fails anything still over 10 s.
- Loops seamlessly (first ≈ last frame). Nothing enforces this; generator drops usually do NOT loop,
  so a visible jump every cycle is a content decision, not an encoder bug.
- **Keep the masters outside the repo** (`tools/content-import/` stages under `c:/Anish/arul-import/`)
  — a whole catalogue once had to be re-encoded, which worked only because masters existed.
- Moderation queue: **never approve a user-submitted video whose dimensions fail the rule** — the
  approve flow copies bytes verbatim. Re-encode with the recipe above, or reject.
