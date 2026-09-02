---
description: Read colours by role from ArulTokens; never seed a scheme, never a literal in a screen.
paths:
  - "lib/theme/**"
  - "lib/app/theme/**"
---

- **Read colours by role from `lib/theme/arul_tokens.dart` (`ArulTokens`).** `lib/app/theme/tokens.dart`
  (`ArulColors`) is the LEGACY ladder, kept only so the `ThemeData` layer did not need a big-bang
  rename; its values are already remapped onto the same palette, but **new code must not grow it**.
- **No literal `Color(0x…)` in screens.** Two exceptions already exist in the tree and nothing else:
  CustomPainter ARTWORK (the ringtone tile's grounds and ink, and every painted motif — those are
  pictures, not chrome, and must NOT become tokens), and `Color(0x00000000)` as a system-bar
  sentinel.
- **Schemes are hand-specified, NOT `ColorScheme.fromSeed`** — it invents its own secondary and
  tertiary. **Never seed from device wallpaper or dynamic color.**
- Light, Dark and System are all required, and the choice is persisted.
- **The UI is Arul's own** — never clone Pakiza's look or sync a theme change. The single exception is
  `ArulEarnButton`, a deliberate port (CLAUDE.md §0).
- Perf rules SHAPE the design and are not optional polish: no glassmorphism anywhere including the
  dock, no `shimmer` package and no `ShaderMask` (a mask forces an offscreen pass — slide a gradient
  fill instead), and no `google_fonts` or `font_awesome_flutter`. Marcellus is BUNDLED, which is the
  only allowed way to add a face.

Read [docs/ui-direction.md](../../docs/ui-direction.md) — it owns the palette, the type stack and the
chrome rules paid for on device.
