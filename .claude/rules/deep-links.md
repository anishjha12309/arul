---
description: Link shapes, intent-filter hazard, one-link share.
paths:
  - "lib/core/deeplink/**"
  - "lib/features/referral/**"
  - "android/**/share/**"
  - "workers/src/routes/deeplink.ts"
  - "lib/features/wallpapers/providers/wallpaper_share_provider.dart"
---

Every trap here fails SILENTLY — nothing logs.

- **Two link shapes are supported, nothing else**: the https App Link (`/w/<uuid>`, `/r/<uuid>`, or
  the id-less form with its TRAILING SLASH) and the Meta `fb<id>://open?…` scheme. Build https links
  with `InstallReferrerService`, never by hand.
- **Intent-filters are never merged across schemes.** A filter matches the cross product of its
  schemes and hosts, so merging registers nonsense hosts and puts a custom scheme under `autoVerify`.
- **ONE level of encoding on `referrer`.** Double-encoding hands the app a single key literally named
  `ref=CODE&w=<uuid>`, and both attribution and the deferred deep link stop working. The Worker's
  language normalisation must match the app's, region-tag stripping included.
- **`ilang=` is SHARE-only; an ad must never carry it** — the caption is already in the sharer's
  language, so a fresh install should land there, while an existing user keeps their own choice.
- **EXACTLY ONE link leaves per share**, owned by the caption and trailing. The old form concatenated
  a second marketing URL, so the recipient had even odds of tapping the one that credits nobody.
- **WhatsApp-first by a DIFFERENT mechanism per path**: a referral is text, so the `whatsapp://send`
  scheme is right; a wallpaper's payload is the FILE, which that scheme silently drops, so it uses a
  native targeted `ACTION_SEND`. A direct-share `false` is ROUTINE — fall through to the sheet.
- **Typed takes:** `consumeWallpaper()` must never eat a pending ringtone, or the reverse.

Read [docs/deep-links.md](../../docs/deep-links.md), [docs/share.md](../../docs/share.md) and
[docs/deferred-links.md](../../docs/deferred-links.md).
