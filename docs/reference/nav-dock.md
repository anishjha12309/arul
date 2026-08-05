# The floating nav dock

> Read this when touching `ArulNavDock` / `AppShell`, adding a tab, or laying out
> anything that scrolls underneath the dock.

Rebuilt 2026-08-05 to `design_handoff_ringtones_screen/README.md` >
"Floating bottom dock" — **that handoff is the normative source for every value**
(height 78, radius 26, 18 side inset, 14 above the safe area, 58-tall tabs,
active cell radius 18, both themes). This file records the decisions around it.

`ArulNavDock` lives in [lib/app/shell/app_shell.dart](../../lib/app/shell/app_shell.dart)
and is public so [test/app/nav_dock_test.dart](../../test/app/nav_dock_test.dart)
can pump it without a router. It is currently unreachable — see
[ringtones-parked/README.md](ringtones-parked/README.md).

## Shape

Three tabs — Wallpapers · Ringtones · **Settings** — and every one shows its icon
AND its label. The dock this replaced slid a solid half-width pill between two
halves (`AnimatedAlign`) and revealed the label only on the active side. That
reads fine with two destinations; with three it leaves two unnamed glyphs and
puts a moving object under the thumb. The active tab is now a still, gold-tinted
rounded cell.

Settings moved *into* the dock in the same change. It used to be a route pushed
over the feed from a header button; a third branch keeps it alive across
switches. **The feed's header gear is gone** (2026-08-05) — it survived the move
for a while and was simply a second door to a tab that already has a permanent
one, which also made Wallpapers the only browse tab with two header actions.
Do not put it back: a dock tab is the entry.

## Rules that are not style choices

- **Colour and geometry come from `ArulTokens.dock*`.** No literals; the light
  theme's active cell is a solid `dockActiveFillLight` because a gold tint on
  ivory would not read.
- **No `backdrop-blur`.** The handoff asks for 14. `BackdropFilter` costs ~6–9 ms
  of raster per frame on mid-tier Android and this capsule sits over a playing
  video feed ([ui-direction.md](../ui-direction.md) > Perf). The opaque
  `dockFillDark` (`#1B1215`) carries the same separation.
- **A fade sits BEHIND the capsule** (`dockScrimAlpha`/`dockScrimStop`, Pakiza's
  treatment). Without it, content keeps scrolling past in the 18px side channels
  and below the capsule, and the dock reads as see-through. Fade to the
  surface's own alpha-0, never `Colors.transparent` — that is transparent BLACK
  and lerping through it smears grey on the ivory theme. The fade takes no hits,
  so a drag starting in it still scrolls the content.
- **No glow on the active cell.** The handoff puts a `0 0 20px` gold halo there;
  on a real panel it fogged the cell's edge and made the dark theme look hazy.
  Fill plus rim is enough. Same reason the now-playing button's halo is a tight
  contact glow rather than the handoff's 14px/35%.
- **Icons are drawn, not Material.** `ArulLineIcon` paints the handoff's stroke
  paths, including a dashed-ring cog Material has no equivalent for. Vector, zero
  asset, no icon font.
- **Labels shrink, they do not clip.** A 1.1 text-scale clamp (the only one in
  the app, matching Pakiza's) plus `Flexible` + `FittedBox(scaleDown)`: the cell
  is a fixed 58 inside a fixed 78, and "വാൾപേപ്പറുകൾ" at 2× would burst it.
  Label metrics carry the theme's own tracking — set at 0 they read as a
  different typeface from the rest of the app.
- **Content clears the dock via `AppShell.dockClearance(context)`** — the
  handoff's 120 plus the bottom safe area, because a 390×844 design frame has no
  gesture bar. Every scrollable AND every empty/loading/error state owes it.
  It returns **0 when there is no `AppShell` above the caller**, which is what
  makes it safe to call unconditionally: Settings is reached both as a dock
  branch and as a route pushed over the feed, and a flat 120 left a screen's
  worth of dead space at the bottom of the pushed one.

## Switching tabs

`ArulBranchCrossfade` (same file) replaces `StatefulShellRoute.indexedStack`'s
single-frame swap with a `tabSwitch` (200ms) dissolve — the router uses a plain
`StatefulShellRoute` with a `navigatorContainerBuilder` so it can. Cutting from a
playing video reel to a list of cards is the jump the eye notices most.

It keeps the fade cheap: every branch stays MOUNTED (so each tab holds its scroll
position), but only the incoming and outgoing ones are `Offstage`-visible, and
`TickerMode` is off for all but the current branch — so a hidden feed's
animations and a hidden diya's flicker stop dead instead of burning frames.
Measured on a Nothing Phone (1): zero dropped frames across a switch.

## Behaviour the dock owns

`AppShell` referees three always-alive branches (`StatefulShellRoute.indexedStack`
keeps them all mounted, so no media system tears itself down when its tab hides):

- leaving **Wallpapers** → `releaseDecoders()` — budget SoCs have very few
  hardware decoders, and the hidden feed must not keep playing;
- returning → `reclaimDecoders()` reconciles the pool onto the feed's current page;
- leaving **Ringtones** → `ringtonePreviewProvider.stop()` (idempotent — the
  screen's own route listener also stops it);
- tapping a tab fires `ArulHaptics.selection()`; re-tapping the active tab pops
  that branch to its root.
