# Share & outbound reach

Read this when changing anything the app sends OUT of itself — a wallpaper share, a referral, or the
copy on either. The link itself (App Links, ad creatives, deferred install) is
[deep-links.md](deep-links.md); the event properties are in
[analytics-events.md](analytics-events.md).

Every outbound message exists to do two things: deliver the thing, and bring someone back. The rules
below are the ones that were paid for by getting the second half wrong.

## Contracts

- [ ] Shares the ACTUAL media file (signed-URL gate, reuses apply's cache) + a referral-link caption.
      Re-sharing an already-cached wallpaper still calls `/media/signed-url` — a cache must never become a
      permanent licence (CLAUDE.md §5).
- [ ] **EXACTLY ONE link leaves the app per share**, and it is the LAST line of the caption.
      The caption OWNS the link (`buildCaption(link)`); it is never appended beside a second one.
      The old form concatenated `'$message\n$link'` where `message` itself ended in a hard-coded
      marketing-site URL — so every shared wallpaper went out with two competing URLs and the
      recipient had even odds of tapping the one that credits nobody. Guarded by a test in
      `wallpaper_share_test.dart`; keep it.
- [ ] Trailing, never inline: messengers preview a link at the end of a message and bury one mid-sentence.
- [ ] **The link carries `ilang=<sharer's language>`, never `lang=`.** The caption is already written
      in the sharer's language, so a friend who INSTALLS from it should land in that language —
      but one who already has Arul must keep the language they chose. `ilang` is what splits those:
      `parseDeepLinkUri` does not read it, so an App Link tap changes nothing, while the Worker
      folds it into the Play referrer's `lang=` for a fresh install (owner's call).
      `lang=` on a share would re-language an existing user from a stranger's phone.
- [ ] **WhatsApp-first, system sheet as fallback — on both paths, by different mechanisms.** This
      asymmetry is load-bearing, not an inconsistency:
      · a **referral** is text, so `whatsapp://send?text=` is right and needs no platform channel
        ← `tell_a_friend.dart`
      · a **wallpaper**'s payload is the FILE, which that scheme silently drops, sending a bare caption.
        It uses a native targeted `ACTION_SEND` + FileProvider URI instead
        ← `DirectShareChannel.kt`, `direct_share_service.dart`
- [ ] A direct-share `false` (no WhatsApp, or it refused the mime type) is ROUTINE — fall through to the
      sheet, never an error toast. `com.whatsapp` AND `com.whatsapp.w4b` must both stay in the manifest's
      `<queries>`, or Android 11+ package visibility hides them and every resolve returns nothing.
- [ ] The FileProvider (`@xml/wallpaper_file_paths`) must keep covering `cache-path` — the watermarked
      copy is written to the temp dir, and a path outside every `<paths>` entry makes the direct share
      degrade to the sheet silently.
- [ ] **The watermark is optional by DEVICE, mandatory by CAPABILITY.** Live burn-in needs API 31 —
      below that Media3 kills the process, not the call ([known-issues.md](known-issues.md)) — so a
      pre-Android-12 live share goes out CLEAN and tracks `share_watermark_skipped` with `sdk_int`.
      On a device that CAN watermark, a failure (after one retry) FAILS the share instead of shipping
      an untraced copy: silently degrading there made the trace code worthless exactly where it works.
      Statics are watermarked on EVERY Android version — that path never touches Media3.
- [ ] Resolving the link never blocks the share (2s timeout, cached summary): the file is the payload,
      the attribution is a bonus. Never invert that. Losing the code must NOT also lose the deep link —
      an uncredited `/w/<id>` still converts; a store listing does not.
- [ ] `link_attributed` tells the truth — never report true for a link with no `ref=`.

## Copy rules

All outbound strings live in `app_en.arb` with these rules written into their `@` descriptions. Keep them
there: the description is the only thing a translator sees.

- **Sender's voice, first person.** The recipient is being messaged by a friend, not by an app.
- **Never mention the sender's own referral reward.** `referShareMessage` used to end "Install it with my
  link and I'll earn free premium" — that reads as self-serving and suppresses the tap. The reward is
  real and the Refer & Earn screen explains it; the message to a friend is not the place.
- **The wallpaper caption does not describe the wallpaper.** The recipient is already looking at it. It
  says where more came from.
- **One line, then the link.** Anything longer gets collapsed by the messenger anyway.

## Entry points

| Surface | `source` | Path |
| --- | --- | --- |
| Feed share button | — | `wallpaper_share_provider` (file + caption) |
| Refer & Earn CTA | `refer_screen` | `tellAFriend` |
| Settings → Tell a friend | `settings` | `tellAFriend` |
| After a purchase | `purchase_success` | `ShareMomentSheet` → `tellAFriend` |
| After an upload | `upload_success` | `ShareMomentSheet` → `tellAFriend` |

`tellAFriend` is the ONE text-share path — copy, attribution and analytics in a single place, because
every surface that re-derived them was a chance to ship the wrong voice or an uncredited link.

The two success moments use a sheet rather than a toast action: since Flutter 3.38 a SnackBar with an
action no longer auto-dismisses, so `showArulToast` has none by design. Both sheets are one tap to
dismiss, and the caller awaits the sheet before popping its own route so it is never left floating over
a screen that has gone.
