# Status clips — encode, QC and poster

Read before encoding, uploading or re-validating a status clip (`statuses/<category>/<uuid>.mp4`). The
shared video rule and the paywall loudness recipe this builds on: [media-conventions.md](media-conventions.md).

The media-verify `status` role (Worker and CMS copies identical) rejects anything but H.264 at
**exactly 1024×1824** (the video rule) with ≥1 audio track, ≤30 s, ≤10 MB. Encode to H.264 High,
limited `yuv420p`, `+faststart`, ~2 Mbps (1.5 Mbps when 2 overshoots), AAC-LC 128k stereo 48 kHz at
**−14 LUFS** with the paywall's two-pass `loudnorm` + limiter, so clips match each other. WhatsApp's
Status composer documents only 720p/1080p: probe one clip through it on a real phone before encoding a
library. `workers/tools/local-seed-statuses.mjs` runs this recipe and validates the output.

**Which clips reach production is the owner's call, per library**: WhatsApp's Share to Status terms make
us warrant the rights. The owner took that risk for the third-party Crafto set's Tamil and Telugu clips
(categories `tamil`, `telugu`); never widen an upload to another language without asking.

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
BG="[0:v]split=2[bg][fg];[bg]scale=1024:1824:force_original_aspect_ratio=increase,crop=1024:1824,gblur=sigma=30,eq=brightness=-0.06[bgb]"
FG="[fg]scale=1024:1824:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,unsharp=5:5:0.6:3:3:0.3[fgs]"
V="[bgb][fgs]overlay=(W-w)/2:(H-h)/2,scale=1024:1824:out_range=tv,setsar=1,format=yuv420p[v]"
ffmpeg -t 29.8 -i in.mp4 -filter_complex "$BG;$FG;$V;[0:a:0]$LN,aresample=48000,alimiter=limit=0.84:level=false[a]" \
  -map "[v]" -map "[a]" -sn -dn -map_metadata -1 -c:v libx264 -profile:v high -preset medium -g 60 \
  -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 -b:v 2000k -maxrate 2400k -bufsize 4000k \
  -c:a aac -profile:a aac_low -b:a 128k -ar 48000 -ac 2 -movflags +faststart out/<uuid>.mp4
ffmpeg -ss 1 -i out/<uuid>.mp4 -frames:v 1 -vf scale=640:-2 -q:v 3 poster/<uuid>.jpg
```
The blurred fill keeps a non-9:16 source whole instead of cropping it. **The app's card trims up to 7.5%
of that fill off each end** ([status.md](status.md) §Player), so a source must be 2:3 or squarer — a
true 9:16 source has no fill, and its title would be the first thing cut.
