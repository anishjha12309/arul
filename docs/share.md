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

## Status clips — a card, then the user picks

- [ ] **Status clips go out CLEAN on Share and Save, on every Android version** (owner). No Media3 export
      on the status path: the re-encode was the long bare wait before every share. `watermarked` stays on
      the status events, always false. The wallpaper rules above are untouched.
- [ ] Tap → the preparing card (`StatusPreparingCard`, root navigator, the sheet's own scrim): one
      localized line per REAL stage and the download's real progress — never a timer, never a percentage.
      Back hides it and abandons the hand-off, but the action guard holds until the fetch settles, so a
      second tap never races the first write into `status-<id>.mp4`.
- [ ] Then the Arul sheet: **Groups · WhatsApp · Status · More** (owner's labels and order). Groups and
      WhatsApp fire the SAME targeted `ACTION_SEND` — WhatsApp's own picker lists chats AND groups, and no
      public intent opens a groups-only one — so they differ only in `status_shared.channel`
      (`groups`|`chat`|`status`|`sheet` = More or no WhatsApp). More = the system sheet.
      Neither WhatsApp package resolves a `video/mp4` send → no Arul sheet, straight to the system sheet.
- [ ] **Status tries WhatsApp's documented composer, then an undocumented action, then the picker.**
      The composer is faq.whatsapp.com/669870872481343: `ACTION_VIEW https://wa.me/status`,
      `share_type=SHARE_TO_STATUS`, explicit `grantUriPermission`, request 5101 that `MainActivity` drops.
      Then `com.whatsapp.intent.action.SEND_TO_STATUS` (explicit grant too: a custom action's stream is
      not migrated to ClipData either).
- [ ] **`wa.me` is WhatsApp's click-to-chat host, so the composer RESOLVES on any consumer WhatsApp**,
      status API or not, and logs `via=composer` either way. `SEND_TO_STATUS` therefore runs only when
      consumer WhatsApp is absent, where it fails too (2.26.39.79 does not declare it): dead in practice.
      The composer is consumer-only, so a Business-only phone's Status cell lands in Business's picker.
- [ ] `status_shared.via` names what opened (`composer`|`send_to_status`|`picker`|`sheet`); only the
      sheet reports a real `result`; `has_whatsapp` separates More from the no-WhatsApp route (both
      `channel=sheet`). Builds before the sheet sent `channel` = what OPENED (`status` = composer, `chat`
      = picker) and no `via`: a row without `via` carries the old meaning. `via` and `has_whatsapp` stay
      out of GA4 reports until registered as custom dimensions ([analytics-ops.md](analytics-ops.md)).
- [ ] **The status surfaces carry NO link** — they take no text; the owner-accepted exception to one link
      per share. The picker and the sheet carry `statusShareCaption` (status videos, never wallpapers)
      with exactly one `/s/<id>?ilang=`, pinned per locale in `status_action_test.dart`.
- [ ] A pick closes the sheet FIRST, then fires; the sheet takes ONE pick — a second tap during its exit
      popped the screen under it in the sister app. A closed sheet or Back on the card shares nothing and
      tracks nothing.

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
