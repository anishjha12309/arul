---
description: Play review sheet — no pre-prompt, later cold open only, the guard, the cap.
paths:
  - "lib/features/review/**"
---

- **Google's sheet and nothing else.** No "Enjoying Arul?", no star gate, no button that calls
  `requestReview` — Play policy, and the quota makes such a button look broken.
- **Play reports nothing** — not shown, not rated. A completed call consumes the arm and a cap slot;
  a `PlatformException` restores both. Never branch on "did they rate".
- **Arm on success, ask on a LATER cold open**, once per process, ≤ 1 per rolling 30 days (Play's
  quota drops a second). A skip keeps the arm. Arming never fails a set that already succeeded.
- **The guard is `canPop()` up every navigator, never `ModalRoute.of`** (it subscribes the feed), plus
  `resumed` lifecycle and `ArulDeepLink.landedThisLaunch`.

Read [docs/review-prompt.md](../../docs/review-prompt.md) before changing any of it.
