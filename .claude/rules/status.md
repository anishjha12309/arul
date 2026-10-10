---
description: Status tab — fixed dock tab, lazy catalog, premium gate, MediaStore save.
paths:
  - "lib/features/status/**"
  - "android/app/src/main/kotlin/**/status/**"
---

- **Status is a fixed dock tab — never gate it on the remote config**, which lands after the first
  paint and grows the dock mid-launch. Older builds still read `feature_flags.status_tab`: keep it `true`.
- **The catalog drains on the first open of the tab**, never before the first paint.
- **Share and Save are premium and gate like the feed**: await `entitlementProvider.future`, then
  `/media/signed-url` (`kind: status`, `action: share|download`) on EVERY action — a cached clip is
  never a licence. Blocked → `status_{share,save}_blocked_premium` + `noteGate` → `/premium?source=`.
- **Save never asks a permission on API 29+**; Android ≤9 asks `WRITE_EXTERNAL_STORAGE` on the first
  save under its own request code (5002), never at launch. Never request `READ_MEDIA_*`.
- **Status clips go out clean** (owner): Share and Save never touch `ShareWatermarkService`.
- **A card is its clip's own shape, whole** (owner): `FeedCardGeometry.contain(slot, status.aspect)`,
  then `BoxFit.fill` — never cover, never bars, never a blur beside the clip.
- Share = preparing card → Groups · WhatsApp · Status · More (owner's labels and order); no WhatsApp →
  the system sheet. The status surfaces (composer, `SEND_TO_STATUS`) carry no link; the picker and
  the sheet carry the `/s/` link ALONE, never a sentence. A closed sheet tracks nothing.

Read [docs/status.md](../../docs/status.md); reel and audio rules are
[docs/video-feed.md](../../docs/video-feed.md).
