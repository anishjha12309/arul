---
description: The ₹99 doors no pay tap opens — premium tap, app-open sheet, Uninstall shortcut — and their one rule.
paths:
  - "lib/features/premium/domain/winback_*.dart"
  - "lib/features/premium/data/uninstall_shortcut_*.dart"
  - "lib/features/premium/providers/winback_reach_providers.dart"
  - "lib/features/premium/presentation/winback_open_trigger.dart"
  - "lib/core/launch/**"
  - "android/**/shortcut/**"
---

- **One rule, `winbackReachable`**: not premium, offered ₹99 by the Worker, trial spent, not `pending`. The
  push alone keeps `winbackOffered` (it asks a paid revoker before the period ends).
- **No checkout nobody tapped**: these doors call `_winbackFirst` directly, never `_startPaid`, and a decline
  only closes. ₹199-on-decline lives only on the pay button's own sheet (`entry == null`).
- **The "Uninstall" label stays true**: every tap ends at the ₹99 sheet with "Uninstall anyway" or at App
  info. Never `disableShortcuts` (a pinned copy would lie); no `REQUEST_DELETE_PACKAGES`.
- **Sync only on a verdict**: no native call while `/me` or the config is loading or failed.
- **A sheet-only door still watches `/me`**, or the open-time reconcile leaves its await hung.
- **The app-open sheet**: every fresh start, never a resume, nothing stored on the phone (owner; brake =
  `open_sheet: false`), and one unrequested surface per launch through `launchMomentProvider` (push ask,
  app-open sheet, review).
- Switches `feature_flags.winback_reach.*` are ON unless exactly `false`.

Read [docs/winback-reach.md](../../docs/winback-reach.md) before changing any of it.
