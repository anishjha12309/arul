# Share & outbound reach

Read when changing anything the app sends OUT — a wallpaper share, a referral, or the copy on either.
The link itself (App Links, ad creatives, deferred install): [deep-links.md](deep-links.md) · event
properties: [analytics-events.md](analytics-events.md). Every outbound message must deliver the thing
AND bring someone back; these rules were paid for by getting the second half wrong.

## The payload

- [ ] Shares the ACTUAL media file (signed-URL gate, reusing apply's cache) plus a caption carrying the
      link. Re-sharing a cached wallpaper still calls `/media/signed-url` — a cache must never become a
      permanent licence ([architecture.md](architecture.md) §Entitlement).
- [ ] **WhatsApp-first, system sheet as fallback — on both paths, by DIFFERENT mechanisms.** A
      **referral** is text, so `whatsapp://send?text=` is right (`tell_a_friend.dart`). A **wallpaper**'s
      payload is the FILE, which that scheme silently drops, sending a bare caption — so it uses a
      native targeted `ACTION_SEND` + FileProvider URI (`DirectShareChannel.kt`,
      `direct_share_service.dart`). The asymmetry is load-bearing.
- [ ] A direct-share `false` (no WhatsApp, or it refused the mime type) is ROUTINE — fall through to the
      sheet, never an error toast. `com.whatsapp` AND `com.whatsapp.w4b` stay in the manifest's
      `<queries>`, or Android 11+ package visibility hides them and every resolve returns nothing.
- [ ] The FileProvider (`@xml/wallpaper_file_paths`) keeps covering `cache-path` — the watermarked copy
      is written to the temp dir, and a path outside every `<paths>` entry silently degrades the direct
      share to the sheet.
- [ ] **The watermark is optional by DEVICE, mandatory by CAPABILITY.** Live burn-in needs API 31 — below
      it Media3 kills the process ([known-issues.md](known-issues.md)) — so a pre-Android-12 live share
      goes out CLEAN and tracks `share_watermark_skipped` with `sdk_int`. On a device that CAN watermark,
      a failure (after one retry) FAILS the share rather than shipping an untraced copy. Statics are
      watermarked on every Android version — that path never touches Media3.
- [ ] Share has a re-entrancy guard, like apply and set: a double tap must not run two flows.

## Attribution

- [ ] **EXACTLY ONE link leaves per share, and it is the LAST line of the caption.** The caption OWNS
      the link (`buildCaption(link)`); it is never appended beside a second one — a caption that also
      carried a marketing-site URL gave the recipient even odds of tapping the one that credits
      nobody. Pinned by `wallpaper_share_test.dart`. Trailing, never inline: messengers preview a link
      at the end of a message and bury one mid-sentence.
- [ ] **The link carries `ilang=<sharer's language>`, never `lang=`.** A friend who INSTALLS from it
      lands in the caption's language, but one who already has Arul keeps their own: `parseDeepLinkUri`
      does not read `ilang`, while the Worker folds it into the Play referrer's `lang=` for a fresh
      install (owner's call). `lang=` would re-language an existing user from a stranger's phone.
- [ ] Resolving the link never blocks the share (2 s timeout, cached summary): the file is the payload,
      attribution a bonus. Losing the referral code must NOT also lose the deep link — an uncredited
      `/w/<id>` still converts; a store listing does not.
- [ ] `link_attributed` tells the truth — never true for a link with no `ref=`.
- [ ] **`tellAFriend` is the ONE text-share path** — copy, attribution and analytics in one place; every
      surface that re-derived them was a chance to ship the wrong voice or an uncredited link.

## Copy rules

All outbound strings live in `app_en.arb` with these rules in their `@` descriptions — the description
is the only thing a translator sees, so keep them there.

- **Sender's voice, first person** — the recipient is messaged by a friend, not an app.
- **Never mention the sender's own referral reward** — "…and I'll earn free premium" reads as
  self-serving and suppresses the tap. The Refer & Earn screen explains the reward.
- **The wallpaper caption never describes the wallpaper** — the recipient is looking at it. It says
  where more came from.
- **One line, then the link** — messengers collapse anything longer.

The post-purchase and post-upload moments use a one-tap sheet, not a toast action: since Flutter 3.38 a
SnackBar with an action no longer auto-dismisses, so `showArulToast` has none. The caller awaits the
sheet before popping its own route, so it never floats over a screen that has gone.
