# Media Conventions

No server-side transcoding. Transcode locally, upload via CMS (`arul-api.hsrutility.com/admin`)
or, for bulk import, direct R2 + one DB transaction (content-ops skill). Full QC battery incl.
faststart/audio-stream checks: reference `c:\Anish\Pakiza\wallpaper-media-spec.md`.
Content kinds: wallpapers (static + live) AND ringtones (audio + optional cover — added 2026-07-17,
see the Ringtones section below).

## R2 keys & formats (bucket `south-indian-wallpapers`)

**Existing content layout (verified via S3 listing 2026-07-14):** `wallpapers/<category>/<16-hex>.{jpg|mp4}`
— 6 category folders (amman, ayyappan, murugan, perumal, sivan, temples), 211 static JPG + 217 live MP4
= 428 assets, all within size caps (max jpg 1.6 MB, max mp4 12 MB). `catalog/catalog.json` is the
content-prep MANIFEST (id, mediaKey, mediaType, category/subjectName, delivered dims, qcStatus) — the
import source for Phase 3, NOT the app catalog (build-catalog writes `catalog/wallpapers/…` beside it).
Sampled files conform: mp4 = 1024×1824 h264 yuv420p, no audio, faststart; jpg = 1080×1920.
Existing keys stay as-is — `full_key` is arbitrary text and the sweep covers all of `wallpapers/`.

**NEW uploads keep the SAME category-partitioned convention** — `wallpapers/<category>/{uuid}.{jpg|mp4}`.
Do NOT adopt the reference's `posters/` vs `full/` split: that partitions by static-vs-live, and Arul
partitions by category (the CMS asks for a category; approval of a user submission copies the object to
that category's prefix). Sweep prefix stays `wallpapers/`, so it covers every category folder.

| Type | R2 key (NEW uploads via CMS) | Input | Output | Max |
|------|------------------------------|-------|--------|-----|
| Wallpaper (static) | wallpapers/&lt;category&gt;/{uuid}.jpg | JPG/PNG/WEBP | 1080×1920 JPG | 10 MB |
| Wallpaper (live) | wallpapers/&lt;category&gt;/{uuid}.mp4 | MP4/MOV | **1024×1824** H.264 MP4 faststart, no audio | 50 MB |
| Ringtone (audio) | ringtones/&lt;category&gt;/{uuid}.mp3 | MP3/M4A/AAC | MP3 (libmp3lame), recommend ≤40s | 15 MB |
| Ringtone (cover) | ringtones/covers/&lt;category&gt;/{uuid}.jpg | JPG/PNG/WEBP | 512×512 JPG q~80 | ≤300 KB |

**THE video rule: width % 128 == 0, height % 32 == 0, AND fits the 1088×1920 hw-decoder cap**
(min side ≤ 1088, max side ≤ 1920). Verified on-device (SD695 + Dimensity 900): budget hw decoders
fit only ~2 concurrent 1080p sessions, so extra feed players SILENTLY fall back to the software
decoder; on that path gralloc pads the buffer width (128px Qualcomm, 64px MTK) and Flutter's
ImageReader samples the full padded buffer ignoring the crop rect (flutter/flutter#174026) →
zeroed-YUV GREEN edge strip. Dead ends already tried: 16-align FAILED, 64-align FAILED on
Qualcomm, >1088 wide FAILED (exceeds vendor caps → permanent sw decode), Skia opt-out FAILED
(ImageReader-backed on both renderers). **Canonical: 1024 = 128×8, 1824 = 32×57, ≈9:16.**
Static posters stay 1080×1920 — images never pass through a video decoder; do not "align" them.

## ffmpeg recipes

**Static wallpaper:**
```bash
ffmpeg -i input.jpg -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920" -q:v 4 output/{uuid}.jpg
```

**Live wallpaper (H.264 faststart, 128/32-aligned dims — rule above):**
```bash
ffmpeg -i input.mov -vf "scale=1024:1824:force_original_aspect_ratio=increase,crop=1024:1824" \
  -c:v libx264 -preset slow -crf 23 -maxrate 4M -bufsize 8M -pix_fmt yuv420p -an -movflags +faststart output/{uuid}.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=width,height output/{uuid}.mp4   # MUST print 1024 / 1824
```

## Ringtones (added 2026-07-17 — strip reversed, see docs/port-map.md)

Audio: output is always MP3 (input MP3/M4A/AAC), ≤15 MB hard cap, recommend ≤40s.
Cover: optional 512×512 JPG, quality ~80, ≤300 KB.
Both live under the `ringtones/` R2 prefix (covered by the canonical sweep — a DB row's
`audio_key` AND `cover_key` both shield their objects):
- audio → `ringtones/<category>/<uuid>.mp3`
- cover → `ringtones/covers/<category>/<uuid>.jpg`

**Ringtone audio:**
```bash
ffmpeg -i in.m4a -c:a libmp3lame -q:a 4 out/<uuid>.mp3
```

**Ringtone cover (512×512 JPG q~80):**
```bash
ffmpeg -i cover.png -vf scale=512:512 -q:v 3 out/<uuid>.jpg
```

## Checks before upload / import
- Dimensions exact: static 1080×1920 · live 1024×1824 (w%128==0, h%32==0, fits 1088×1920 cap)
- Extension matches mime (mp4→video/mp4, jpg→image/jpeg); file size within limits
- Live MP4: faststart (moov before mdat) · NO audio stream · first frame representative, not black
  (the feed shows shimmer until the first decoded frame — a black first frame looks broken)
- Loops seamlessly (first ≈ last frame); 5–15s @30fps is the practical range (convention, not enforced)
- Keep the masters (likely `C:\Anish\content-wallpaper(southindian)`) — the reference catalog once
  had to be fully re-encoded; that only worked because masters existed
- Moderation queue: NEVER approve a user-submitted video as-is unless dims pass the rule — the
  approve flow copies bytes verbatim. Re-encode with the recipe or reject.
