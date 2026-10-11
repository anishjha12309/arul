---
description: Toasts, sheets and dialogs share one surface, one motion family and the root overlay.
paths:
  - "lib/app/widgets/arul_toast.dart"
  - "lib/app/widgets/arul_sheet.dart"
  - "lib/app/widgets/arul_dialog.dart"
  - "lib/app/widgets/arul_surface.dart"
  - "lib/app/widgets/arul_pressable.dart"
  - "lib/app/widgets/arul_ornaments.dart"
  - "lib/features/**/*sheet*.dart"
  - "lib/features/**/*dialog*.dart"
  - "lib/features/status/presentation/status_preparing_card.dart"
---

- **A raised surface is `ArulSurface`** — never a hand-rolled `Container` card. Sheets pass `rim: false`;
  `/premium` passes its cream as `color`, which turns the gradient and the lit edge off.
- **A sheet's only motion is its route's rise** (`showArulSheet` → `Motion.sheet`). Never add a fade or a
  slide inside it: an animated `Opacity` is an offscreen layer on every frame of the rise.
- **Dialogs go through `showArulDialog`** (root navigator, caller's theme captured, exit in half the
  entrance). Never `showDialog`/`showGeneralDialog`: one duration serves both ways and the theme is lost.
- **Toasts go through `showArulToast` only** — the root overlay, one at a time, the ONE home of the outcome
  haptic. Never a `SnackBar` (it shows under an open sheet's scrim and cannot take our curve).
- **Every tappable inside is `ArulPressable`**: haptic on press-DOWN, a scale dip, a tint in the accent's
  wash. A press changes a rim's COLOUR, never its width.
- Colours are `ArulPalette` roles; durations and curves are `Motion` — no literal in an overlay.
- Reduced motion holds everything at rest (no-animation style, zero-length route, toast at rest); the
  haptic still fires.
- A new overlay or toast message is a registry entry in `test/l10n/support/registry.dart`, so the
  six-language matrix measures it.

Read [docs/overlays.md](../../docs/overlays.md) before changing any of it.
