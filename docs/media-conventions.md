# Media Conventions

No server-side transcoding — ever. Transcode locally, then upload through the unified CMS
(`api.hsrutility.com/admin/arul`) or, for bulk jobs, direct to R2 plus one DB transaction
(`tools/content-import/`, content-ops skill). Content kinds: wallpapers (static + live) and ringtones
(audio + optional cover).

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
| Wallpaper (live) | wallpapers/&lt;category&gt;/{uuid}.mp4 | MP4/MOV | **1024×1824** H.264 MP4 faststart, no audio | 50 MB |
| Ringtone (audio) | ringtones/&lt;category&gt;/{uuid}.mp3 | MP3/M4A/AAC | MP3 (libmp3lame), ≤40 s recommended | 15 MB |
| Ringtone (cover) | ringtones/covers/&lt;category&gt;/{uuid}.jpg | JPG/PNG/WEBP | 512×512 JPG q~80 | ≤300 KB |

Both ringtone keys sit under the `ringtones/` prefix, and a row's `audio_key` AND `cover_key` each
shield their object from the canonical sweep.

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

**Static wallpaper:**
```bash
ffmpeg -i input.jpg -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -q:v 4 output/{uuid}.jpg
```

**Live wallpaper** (H.264 faststart, 128/32-aligned):
```bash
ffmpeg -i input.mov -vf "scale=1024:1824:force_original_aspect_ratio=increase,crop=1024:1824" \
  -c:v libx264 -preset slow -crf 23 -maxrate 4M -bufsize 8M -pix_fmt yuv420p -an -movflags +faststart output/{uuid}.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height output/{uuid}.mp4   # MUST print 1024 / 1824
```

**Ringtone audio:**
```bash
ffmpeg -i in.m4a -c:a libmp3lame -q:a 4 out/<uuid>.mp3
```

**Ringtone cover:**
```bash
ffmpeg -i cover.png -vf scale=512:512 -q:v 3 out/<uuid>.jpg
```

## Checks before upload / import
- Dimensions exact: static 1080×1920 · live 1024×1824 (w%128==0, h%32==0, inside the 1088×1920 cap)
- Extension matches mime (mp4→video/mp4, jpg→image/jpeg); size within the caps above
- Live MP4: faststart (moov before mdat) · **no audio stream** · first frame representative, not black
  — the feed shows shimmer until the first decoded frame, so a black first frame looks broken
- Loops seamlessly (first ≈ last frame); 5–15 s @30 fps is the practical range (convention, not enforced)
- Keep the masters somewhere outside the repo. The original South Indian master folder
  (`C:\Anish\content-wallpaper(southindian)`) **no longer exists on disk**; `tools/content-import/`
  stages under `c:/Anish/arul-import/` instead. Pakiza's catalogue once had to be fully re-encoded, and
  that only worked because masters existed.
- Moderation queue: **never approve a user-submitted video whose dimensions fail the rule** — the
  approve flow copies bytes verbatim. Re-encode with the recipe above, or reject.
