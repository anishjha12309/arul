# Share & outbound reach

Read when changing anything the app sends OUT — a wallpaper share, a tell-a-friend, or the copy on either.
The link itself (App Links, ad creatives, deferred install): [deep-links.md](deep-links.md) · event
properties: [analytics-events.md](analytics-events.md). Every outbound message must deliver the thing
AND bring someone back; these rules were paid for by getting the second half wrong.

## The payload

- [ ] Shares the ACTUAL media file (signed-URL gate, reusing apply's cache) plus a caption carrying the
      link. Re-sharing a cached wallpaper still calls `/media/signed-url` — a cache must never become a
      permanent licence ([architecture.md](architecture.md) §Entitlement).
- [ ] **WhatsApp-first, system sheet as fallback — on both paths, by DIFFERENT mechanisms.** A
      **tell-a-friend** is text: a targeted text `ACTION_SEND`, then `whatsapp://send?text=`
      (`lib/features/share/tell_a_friend.dart`). A **wallpaper**'s
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

## Status clips — composer, then chat, then sheet

- [ ] **WhatsApp's Share to Status composer first** (faq.whatsapp.com/669870872481343): `ACTION_VIEW
      https://wa.me/status`, `setPackage("com.whatsapp")`, `share_type=SHARE_TO_STATUS`,
      `EXTRA_STREAM` plus an EXPLICIT `grantUriPermission` — an ACTION_VIEW's stream is not migrated to
      ClipData, so the flag alone grants nothing. Consumer WhatsApp only: `false` (absent, too old,
      Business only) is routine and falls to the wallpaper path's targeted chat `ACTION_SEND`, then the
      sheet. It is started for a result nobody reads (5101), which `MainActivity` keeps off the plugin chain.
- [ ] **The composer carries NO link** — it takes no text; the owner-accepted exception to one link per
      share. The chat and sheet fallbacks carry `referShareMessage` with exactly one `/s/<id>?ilang=`.
- [ ] Share and Save use the same traced copy under the live-share watermark rule; below API 31 the clip
      goes out clean as `watermarked: false` on the status event, not `share_watermark_skipped`.

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
- [ ] **No referral code leaves the app** (owner: Refer & Earn dropped). The wallpaper link is built
      synchronously — no round trip sits between the tap and the share — and tell-a-friend sends the
      plain Play listing. Never re-add `ref=`: the Worker still passes it through for old builds' links,
      but nothing credits a new one.
- [ ] **`tellAFriend` is the ONE text-share path** — copy, link and analytics (`referral_shared
      {source}`, the name kept for dashboard continuity) in one place; every surface that re-derived
      them was a chance to ship the wrong voice or the wrong link.

## Copy rules

All outbound strings live in `app_en.arb` with these rules in their `@` descriptions — the description
is the only thing a translator sees, so keep them there.

- **Sender's voice, first person** — the recipient is messaged by a friend, not an app.
- **Never mention a reward** — "…and I'll earn free premium" reads as self-serving and suppresses the
  tap, and no reward exists for a new share.
- **The wallpaper caption never describes the wallpaper** — the recipient is looking at it. It says
  where more came from.
- **One line, then the link** — messengers collapse anything longer.

The post-purchase and post-upload moments use a one-tap sheet, not a toast action: since Flutter 3.38 a
SnackBar with an action no longer auto-dismisses, so `showArulToast` has none. The caller awaits the
sheet before popping its own route, so it never floats over a screen that has gone.
