---
description: Link shapes, intent-filter hazard, one-link share.
paths:
  - "lib/core/deeplink/**"
  - "lib/features/share/**"
  - "lib/features/status/**"
  - "android/**/share/**"
  - "workers/src/routes/deeplink.ts"
  - "lib/features/wallpapers/providers/wallpaper_share_provider.dart"
---

Every trap here fails SILENTLY — nothing logs.

- **Two link shapes only**: https App Link (`/w/<uuid>`, `/r/<uuid>`, `/s/<uuid>`, id-less `/w/` `/w`
  `/r/` `/r` `/s/` `/s` `/`) and Meta `fb<id>://open?…`. Each path needs a manifest filter, a Worker
  ROUTE (handler tests skip Hono's strict router) and `parseDeepLink`; native checks the host ONLY.
  A Worker route never 404s — builds without the filter open a browser there and bounce to Play.
- **Intent-filters are never merged across schemes.** A filter matches the cross product of its
  schemes and hosts, so merging registers nonsense hosts and puts a custom scheme under `autoVerify`.
- **ONE level of encoding on `referrer`.** Double-encoding hands the app a single key literally named
  `ref=CODE&w=<uuid>`, and both attribution and the deferred deep link stop working. The Worker's
  language normalisation must match the app's, region-tag stripping included.
- **`ilang=` is SHARE-only; an ad must never carry it** — the caption is already in the sharer's
  language, so a fresh install should land there, while an existing user keeps their own choice.
- **EXACTLY ONE link leaves per share**, owned by the caption and trailing. The old form concatenated
  a second marketing URL, so the recipient had even odds of tapping the one that credits nobody. The
  one exception (owner): WhatsApp's status composer takes no text, so it carries none; its chat and
  sheet fallbacks carry exactly one `/s/` link.
- **WhatsApp-first by a DIFFERENT mechanism per path**: tell-a-friend is text (targeted text
  `ACTION_SEND`, then the `whatsapp://send` scheme); a wallpaper's payload is the FILE, which that scheme silently drops, so it uses a
  native targeted `ACTION_SEND`. A direct-share `false` is ROUTINE — fall through to the sheet.
- **Typed takes:** `consumeWallpaper()` must never eat a pending ringtone or status, or the reverse.

Read [docs/deep-links.md](../../docs/deep-links.md), [docs/share.md](../../docs/share.md) and
[docs/deferred-links.md](../../docs/deferred-links.md).
