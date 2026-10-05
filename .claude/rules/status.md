---
description: Status tab — remote flag, lazy catalog, premium gate, MediaStore save.
paths:
  - "lib/features/status/**"
  - "android/app/src/main/kotlin/**/status/**"
---

- **`feature_flags.status_tab` off, absent or loading = the two-tab app and NO status catalog fetch.**
  Only a literal `true` shows the tab; the branch stays declared and only the dock item hides.
- **The catalog drains on the first open of the tab**, never before the first paint.
- **Share and Save are premium and gate like the feed**: await `entitlementProvider.future`, then
  `/media/signed-url` (`kind: status`, `action: share|download`) on EVERY action — a cached clip is
  never a licence. Blocked → `status_{share,save}_blocked_premium` + `noteGate` → `/premium?source=`.
- **Save never asks a permission on API 29+**; Android ≤9 asks `WRITE_EXTERNAL_STORAGE` on the first
  save under its own request code (5002), never at launch. Never request `READ_MEDIA_*`.
- The WhatsApp status composer carries no link; its fallbacks carry exactly one `/s/` link.

Read [docs/status.md](../../docs/status.md); reel and audio rules are
[docs/video-feed.md](../../docs/video-feed.md).
