# Status clips — encode, QC and poster

Read before encoding, uploading or re-validating a status clip (`statuses/<category>/<uuid>.mp4`). The
shared video rule and the paywall loudness recipe this builds on: [media-conventions.md](media-conventions.md).

The media-verify `status` role (Worker and CMS copies identical) rejects anything but H.264 **on the
video rule at the source's own shape** (width a multiple of 128, height of 32, inside 1088×1920: a 2:3
source at 1024 wide is 1024×1536, a 9:16 one 1024×1824) with ≥1 audio track, ≤30 s, ≤10 MB. Never pad
to one canvas: the blurred fill put a blur band above every title, and the card shows each clip at its
own shape (owner, after Shubh).
The catalog carries `width`/`height` so the card is sized before the first frame. Encode to H.264 High,
limited `yuv420p`, `+faststart`, ~2 Mbps (1.5 Mbps when 2 overshoots), AAC-LC 128k stereo 48 kHz at
**−14 LUFS** with the paywall's two-pass `loudnorm` + limiter, so clips match each other. WhatsApp's
Status composer documents only 720p/1080p: probe one clip through it on a real phone before encoding a
library. `workers/tools/local-seed-statuses.mjs` runs this recipe and validates the output.

**A user submission (`kind: status`) must arrive already on this rule — H.264 MP4 with sound, ≤30 s,
≤10 MB, video-rule dimensions** — because nothing transcodes server-side. `/media/upload-url` refuses a
non-MP4 or over-10 MB claim; `/media/confirm-upload` runs this `status` role on the landed bytes and
deletes a failure, returning its code ([architecture.md](architecture.md) §Uploads).

**The app makes a picked clip compliant on the phone** (`video_plan.dart`, Android 12+): the largest size
on the video rule within 2% of the clip's own aspect, never above it (1080×1920 → 1024×1824, 720×1280 →
640×1152), H.264 High ~2 Mbps, AAC 128k, cut at 29.8 s. **One retry over 10 MB steps the SIZE down
too**, aimed at 85% of the cap: MediaTek's AVC encoder ignores the bitrate in every mode (A001: 2 and
1.5 Mbps both wrote 4.3, a 16.7 MB clip), has no CBR (asking for it fails the export), and the software
encoder's slow-CPU variant caps near 410×730 — only the pixel count moves its bytes. Two recipe
steps are skipped: the −14 LUFS `loudnorm` (no on-device equivalent) and the 48 kHz resample. A clip
with no audio track is refused before converting, as the server would refuse it.

**Which clips reach production is the owner's call, per library**: WhatsApp's Share to Status terms make
us warrant the rights. The owner took that risk for the third-party Crafto set's Tamil and Telugu clips
(categories `tamil`, `telugu`), then approved Kannada and Malayalam (`kannada`, `malayalam`) for the
photo-frame set; never widen an upload to another language without asking. A category is named after
its language because the app leads with the app language's category ([status.md](status.md) §Language).

**The Crafto "with photo frame" set carries `photo_slot`** (on `statuses`: jsonb, nullable; the catalog
row carries it as stored): `{left, top, size, shape}`, `left` and `size` as fractions of the clip's
WIDTH, `top` of its HEIGHT, the slot a square of side `size` × width; shape `circle`, `soft_circle`,
`pin`, `soft_square` or `square`, an unknown one drawn as a circle. Fractions, so any encode size maps
the same.

NULL (no frame: a CMS upload, any older clip) → the app's corner avatar. An app without the photo
feature ignores the field; the clip plays like any other.

**Encode that set at 768×1152, not 1024×1536**: still on the video rule, 768 is a 6.7% upscale of the
source where 1024 was 42%, so the same bitrate buys more bits per pixel. It goes up as unpublished
drafts through `workers/tools/status-import.mjs` (flags in its header; build-catalog ships
`is_published` rows only), and the owner swaps old clips for new in the CMS.

Bulk upload = `cd workers && node tools/status-import.mjs --langs tamil,telugu` (encode + QC + plan into
`~/Anish/arul-import/statuses`, writes nothing), then the same with `--write`: R2 clip + poster, ONE Neon
txn (rows, one category per language, one `content_version` bump), rebuild. Ids derive from the Crafto
record, so a re-run refuses rather than doubling. It never touches `status_tab`.

**The poster `thumbs/statuses/<category>/<uuid>.jpg` is REQUIRED at upload** — derived from the clip's
stem, stored in no column, and a missing poster's 404 is edge-cached ([caching.md](caching.md)). It sits
one level below wallpaper thumbs because a status category may reuse a wallpaper slug. Take a non-black
frame (the seed needs `signalstats` YAVG ≥ 32). Trim to 29.8 s, never `-t 30`: AAC frame rounding lands
that at ~30.1 s and QC refuses it.
```bash
ffmpeg -t 29.8 -i in.mp4 -vn -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null -   # pass 1
LN="loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=…:measured_TP=…:measured_LRA=…:measured_thresh=…:offset=…:linear=true"
ffmpeg -t 29.8 -i in.mp4 -filter_complex "[0:v]scale=1024:1536:force_original_aspect_ratio=increase:flags=lanczos:out_range=tv,crop=1024:1536,unsharp=5:5:0.6:3:3:0.3,setsar=1,format=yuv420p[v];[0:a:0]$LN,aresample=48000,alimiter=limit=0.84:level=false[a]" \
  -map "[v]" -map "[a]" -sn -dn -map_metadata -1 -c:v libx264 -profile:v high -preset medium -g 60 \
  -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 -b:v 2000k -maxrate 2400k -bufsize 4000k \
  -c:a aac -profile:a aac_low -b:a 128k -ar 48000 -ac 2 -movflags +faststart out/<uuid>.mp4   # 1536 = the 2:3 source's height snapped to 32
ffmpeg -ss 1 -i out/<uuid>.mp4 -frames:v 1 -vf scale=640:-2 -q:v 3 poster/<uuid>.jpg
```
`tools/lib/status-media.mjs` (`frameFor`, `transcode`, `validate`) is that recipe for any source shape.
**The first library (Oct 2026) was padded to 1024×1824 with a blurred fill**; `node tools/status-reencode.mjs`
(dry run; `--write` for the live run) cuts the bands off every padded clip, copies its levelled audio,
and re-keys the row to `<uuid>-v2.mp4` + poster — same id, counts and `/s/` link; media keys are
immutable-cached, so a new key, never an overwrite. The old objects fall to the canonical sweep.
