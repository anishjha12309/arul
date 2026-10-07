# Edge cases — video reels and the Status tab

The reel half of the regression-contract index ([edge-cases.md](edge-cases.md) holds the rest). One line
per paid-for bug, binding whatever the UI; walk them on device before a release.

## Video reels — [video-feed.md](video-feed.md), [media-conventions.md](media-conventions.md)
- [ ] Live MP4s exactly 1024×1824 — the 128/32 alignment rule inside the hw-decoder cap
- [ ] Players REUSED (`setMediaItem`); ONE process-global EventChannel hub
- [ ] Software fallback demotes the pool 3→2, floor 2; only a codec error goes to 1; never query capability
- [ ] Leaving a reel pauses at once, frees decoders after a 3 s grace; other releases are immediate
- [ ] Entering a reel releases the OTHER reel IN FULL before claiming — no grace, even via a Ringtones hop
- [ ] Two reel pools never decode at once; ONE decoder budget per device, shared by both
- [ ] The feed opens FILES, never a stream by plan; a network error never re-opens a painted card
- [ ] Poster under the texture, revealed on `onRenderedFirstFrame`; one shared `cropAlignment`
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
- [ ] Save is a fresh MediaStore entry, copied off the main thread; ≤Android 9 asks storage on the first
      save, never at launch; a denial is a localized message
- [ ] Entering Status stops the ringtone preview
