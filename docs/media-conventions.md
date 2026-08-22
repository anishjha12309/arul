# Media Conventions

No server-side transcoding — ever. Transcode locally, then upload through the unified CMS
(`api.hsrutility.com/admin/arul`) or, for bulk jobs, direct to R2 plus one DB transaction
(`tools/content-import/`, content-ops skill). Content kinds: wallpapers (static + live) and ringtones
(audio only).

## R2 keys & formats (bucket `south-indian-wallpapers`)

Everything is **category-partitioned**: `wallpapers/<category>/<uuid>.{jpg|mp4}` across the 6
categories (amman, ayyappan, murugan, perumal, sivan, temples). Objects imported in 2026-07 use a
16-hex stem instead of a UUID — `full_key` is arbitrary text, so both are fine and old keys stay as-is.

**Do NOT adopt Pakiza's `posters/` vs `full/` split.** That partitions by static-vs-live; Arul
partitions by category, because category is the browse axis and approval of a user submission copies
the object into that category's prefix. The sweep prefix stays `wallpapers/`, so it covers every
category folder.

| Type | R2 key | Input | Output | Max |
|------|--------|-------|--------|-----|
| Wallpaper (static) | wallpapers/&lt;category&gt;/{uuid}.jpg | JPG/PNG/WEBP | 1080×1920 JPG | 10 MB |
| Wallpaper (live) | wallpapers/&lt;category&gt;/{uuid}.mp4 | MP4/MOV | **1024×1824** H.264 MP4 faststart, no audio, **≤10 s** | **15 MB** |
| Ringtone (audio) | ringtones/&lt;category&gt;/{uuid}.mp3 | MP3/M4A/AAC | MP3 (libmp3lame), ≤40 s recommended | 15 MB |

**There is no ringtone cover role** — row art is drawn in-app, so the role was removed 2026-08-10 and
the CMS refuses to presign one. Do not re-add a cover pipeline. The canonical sweep still reads
`cover_key` (null on every row) into its keep-set alongside `audio_key`; leave that as-is.

## THE video rule: width % 128 == 0, height % 32 == 0, and inside the 1088×1920 hw-decoder cap

Verified on-device (SD695 + Dimensity 900). Budget hardware decoders fit only ~2 concurrent 1080p
sessions, so extra feed players SILENTLY fall back to the software decoder; on that path gralloc pads
the buffer width (128 px Qualcomm, 64 px MTK) and Flutter's ImageReader samples the full padded buffer
while ignoring the crop rect (flutter/flutter#174026) → a zeroed-YUV **green edge strip**.

Dead ends already tried, do not retry: 16-align FAILED · 64-align FAILED on Qualcomm · >1088 wide
FAILED (exceeds vendor caps → permanent software decode) · Skia opt-out FAILED (ImageReader-backed on
both renderers).

**Canonical: 1024 = 128×8, 1824 = 32×57, ≈9:16.** Static posters stay 1080×1920 — images never pass
through a video decoder, so do not "align" them.

## ffmpeg recipes

**Sources arrive at 720×1280, so most clips are UPSCALED 1.42× to 1024 wide** — and upscaling cannot
add detail, so `lanczos` + a light `unsharp` + a CRF below the old 24 (which was tuned for
native-res masters and laid mush on an already-soft frame). Measured 2026-08-21: sharpness 35 → 57 at
the same resolution, ~2× the bytes. A source ≥ target is DOWNSCALING — token sharpen only, more just
adds halos. **The geometry never changed and cannot stretch:** `scale(…increase)` + `crop` is a COVER
fit — on a 9:16 source it trims 2 px of width and no height. Stretched output? Suspect the renderer.

**Static wallpaper** (`upscale` chain shown; drop `unsharp` when the source is ≥1080 wide):
```bash
ffmpeg -i input.jpg -vf "scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1920,unsharp=5:5:0.5:3:3:0.0" -q:v 2 output/{uuid}.jpg
```

**Live wallpaper** (H.264 faststart, 128/32-aligned). Upscaled → `unsharp=5:5:0.6:3:3:0.3` + `-crf 21`; native/downscaled → `unsharp=3:3:0.3:3:3:0.0` + `-crf 20`:
```bash
ffmpeg -i input.mov -t 10 -vf "scale=1024:1824:force_original_aspect_ratio=increase:flags=lanczos:out_range=tv,crop=1024:1824,unsharp=5:5:0.6:3:3:0.3,setsar=1,format=yuv420p" \
  -c:v libx264 -profile:v high -preset slow -crf 21 -x264-params aq-mode=3 -an -movflags +faststart output/{uuid}.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt output/{uuid}.mp4  # MUST print 1024 / 1824 / yuv420p
```
`out_range=tv` + `format=yuv420p` are load-bearing: without them ffmpeg emits full-range `yuvj420p`,
which `verify.mjs` rejects — repairing that batch is what `tools/content-import/fix.mjs` exists for
(its encoder MUST stay in lockstep with `normalize.mjs`). `setsar=1` stops a non-square SAR surviving
the crop. `aq-mode=3` spends bits on flat gradients, which is where smoke and sky band.

**15 MB is a hard ceiling, quality-first underneath it** (owner, 2026-08-21): `normalize.mjs` re-encodes
ONLY an overshooting clip, with a `-maxrate` sized from its own duration, so one heavy clip is capped
instead of every clip being pre-emptively starved. Bulk statics go through `sharp` (lanczos3 +
sharpen when upscaling, quality 92) — tuned to match this recipe, not byte-identical to it.

**Ringtone audio:**
```bash
ffmpeg -i in.m4a -c:a libmp3lame -q:a 4 out/<uuid>.mp3
```

## Checks before upload / import
- Dimensions exact: static 1080×1920 · live 1024×1824 (w%128==0, h%32==0, inside the 1088×1920 cap).
  Only `tools/content-import/verify.mjs` enforces the exact figures, and only for bulk imports. The
  LIVE rule is also gated server-side (`media-verify.ts`), so no off-spec clip can land — but a STATIC
  upload is not: the CMS warns and lets the operator confirm past it, and the Worker checks only a
  480..8192 range, which is how two 800px-wide wallpapers reached prod published.
- Extension matches mime (mp4→video/mp4, jpg→image/jpeg); size within the caps above
- Live MP4 `pix_fmt` is limited-range `yuv420p` — `yuvj420p` is a hard import failure
- Live MP4: faststart (moov before mdat) · **no audio stream** · first frame representative, not black
  — the card holds the `thumbs/` poster until the texture reveals, so a black first frame does not
  read as "loading", it reads as a good image being replaced by a broken one
- **≤10 s, and `normalize.mjs` auto-trims to the first 10 s** (owner, 2026-08-21 — a drop arrived
  with 44.8 s and 30.5 s clips). The cut is BLIND: it takes the leading window, so it can land
  mid-motion and will not respect a loop point. It flags `trimmed:<n>s` — review those before
  publishing. `verify.mjs` fails anything still over 10 s
- Loops seamlessly (first ≈ last frame). Nothing enforces this; generator drops usually do NOT loop,
  so a visible jump every cycle is a content decision, not an encoder bug
- Keep the masters somewhere outside the repo. The original South Indian master folder
  (`C:\Anish\content-wallpaper(southindian)`) **no longer exists on disk**; `tools/content-import/`
  stages under `c:/Anish/arul-import/` instead. Pakiza's catalogue once had to be fully re-encoded, and
  that only worked because masters existed.
- Moderation queue: **never approve a user-submitted video whose dimensions fail the rule** — the
  approve flow copies bytes verbatim. Re-encode with the recipe above, or reject.
