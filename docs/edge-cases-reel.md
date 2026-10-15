# Edge cases — video reels and the Status tab

The reel half of the regression-contract index ([edge-cases.md](edge-cases.md) holds the rest). One line
per paid-for bug, binding whatever the UI; walk them on device before a release.

## Video reels — [video-feed.md](video-feed.md), [media-conventions.md](media-conventions.md)
- [ ] Live MP4s exactly 1024×1824; a status any size on the 128/32 rule inside the hw-decoder cap
- [ ] Players REUSED (`setMediaItem`); ONE process-global EventChannel hub
- [ ] Software fallback demotes the pool 3→2, floor 2; only a codec error goes to 1; never query capability
- [ ] Leaving a reel pauses at once, frees decoders after a 3 s grace; other releases are immediate
- [ ] Entering a reel releases the OTHER reel IN FULL before claiming — no grace, even via a Ringtones hop
- [ ] Two reel pools never decode at once; ONE decoder budget per device, shared by both
- [ ] The feed opens FILES, never a stream by plan; a network error never re-opens a painted card
- [ ] Poster under the texture, revealed on `onRenderedFirstFrame`; one shared `cropAlignment`
- [ ] The loading sweep until the poster lands; a reassigned player's stale frame cuts, never dissolves
- [ ] Audio decided at CREATE; only the paywall's ONE shared player and the status pool are audible
- [ ] Only the card on screen starts: a player whose `create()` or transfer outlived a jump (a `/s/`
      link, a swipe) parks idle or opens paused — the A001 played two status clips aloud at once
- [ ] No reel plays while hidden: another tab, a pushed full screen, or the background — a dialog or
      sheet does not pause; a resume never plays a hidden reel
- [ ] Focus taken by another app, or headphones out → the clip holds until a TAP, never resumes itself
- [ ] Data Saver on a metered link stages nothing ahead

## Status tab — [status.md](status.md)
- [ ] Three dock tabs from the first frame of every launch, a fresh install included — no tab pops in
- [ ] A cold status link (App Link, deferred `s=`, Quick Access bar) opens Status without waiting for the config
- [ ] The status catalog loads on the first open of the tab, never in the pre-first-paint drain
- [ ] Status clips prefetch into their OWN cache store — they never evict live wallpapers
- [ ] Share and Save re-read entitlement every time; a cached clip is never a licence
- [ ] No trace watermark on a status; photo/name burnt in only when on AND API 31+, else byte for byte;
      Save sends what Share sends (owner)
- [ ] Card preview and export PNG are ONE painter; the PNG and the exported frame are clip + name band
- [ ] Below API 31: no photo preview, Photo explains itself, clips go out as before
- [ ] No WhatsApp → no Arul sheet; Back on the preparing card or a closed sheet sends and tracks nothing;
      one pick per sheet, and a second tap while an action runs is refused
- [ ] Save is a fresh MediaStore entry, copied off the main thread; ≤Android 9 asks storage on the first
      save, never at launch; a denial is a localized message
- [ ] Entering Status stops the ringtone preview
- [ ] Loading, empty, error and offline faces say status videos, never wallpapers
- [ ] A pull on the first card refreshes and the clips stay on screen through it
- [ ] A cold `/s/` link opens on its clip — card 0 is never opened or staged first
- [ ] One status per page, no peek; the box is the clip's own shape, whole, on a 320 dp phone too
- [ ] The verbs sit in the fixed bar under the reel, never over the clip's bottom edge
- [ ] A malformed `photo_slot` never drops its row; a 768×1152 clip or a new language parses like any
- [ ] The reel is one language's clips, no chips; the sheet lists only languages that have clips
- [ ] None chosen → the sheet asks on every tab visit, not on a return from Settings, never over another
      screen (a catalog that lands behind one asks on the way back); closed = every clip for now. One
      chosen → asks once, preselected
- [ ] A cold `/s/` link skips the sheet and plays its clip first, then the user's language; a pick on a
      sheet the link landed behind keeps the clip first
- [ ] Settings: a language with clips switches Status too; English or Hindi changes only the app text
- [ ] A failed catalog drain reports once per run, however many times Riverpod retries it
- [ ] Groups, WhatsApp and Status in the status share sheet all wear the WhatsApp logo

## Status uploads — [status-clips.md](status-clips.md), [architecture.md](architecture.md) §Uploads
- [ ] A status presigns only as an MP4 ≤10 MB; confirm-upload deletes one off the status rule
- [ ] Upload's category is ONE select field and sheet in every kind; a kind switch drops file and category
- [ ] Upload's Status languages never fetch the status catalog before the Status tab has
