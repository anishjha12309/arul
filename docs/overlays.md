# Overlays — toasts, sheets, dialogs

Read before touching `lib/app/widgets/arul_{toast,sheet,dialog,surface,pressable,ornaments}.dart` or any
`*_sheet.dart` / `*dialog*.dart`. The palette, type and perf rules they rest on: [ui-direction.md](ui-direction.md).

## One surface

- **Every raised surface is `ArulSurface`**: the palette's `sheet` ground (lit from the top on dark by
  `sheetGradient`), the `rim`, the `overlayShadow` (light only — a shadow is invisible on the dark ground)
  and the gold `litEdge` along the rounded top. A sheet passes `rim: false`: it meets the screen's edges.
- The lit edge is a stroke that FADES before each corner. A full-width 1 px hairline gets cut by the
  rounded corners into a stray line; that is not a reason to switch the edge off on a small sheet.
- Corners: a sheet's top and every dialog use `sheetTopRadius`/`dialogRadius` (24), so they read as one
  family. Material's 28 is not ours.
- `/premium`'s sheets keep their cream (`surfaceColor`): a flat `color` turns the gradient and the lit edge
  off by itself. Their dialogs keep the member-view card; only the route (motion) is shared.

## Motion — one curve family, and only one motion per overlay

- Enter `Motion.overlayIn` (400 ms) on `Easing.emphasizedDecelerate`: ~90 % of the travel lands in the
  first 100 ms, then a long settle. Exit `Motion.overlayOut` (200 ms) on `emphasizedAccelerate`.
- **A sheet's ONLY motion is its route's rise** (`showModalBottomSheet(sheetAnimationStyle: Motion.sheet)`;
  custom curves need Flutter ≥ 3.44). Never fade inside the sheet as well: it slides translucent over the
  scrim, and an animated `Opacity` sends the whole sheet through an offscreen layer every frame.
- **Dialogs go through `showArulDialog` → `ArulDialogRoute`**: fade + grow from `dialogScaleFrom` in
  `dialogIn`, out in `overlayOut`. `showGeneralDialog` cannot exit faster than it enters — its single
  `transitionDuration` serves both. The route captures the CALLER's theme (`/premium` pins light).
- Reduced motion: sheets get `AnimationStyle.noAnimation`, dialogs a zero-length route, toasts appear at
  rest. Haptics still fire.

## Toast

- **On the ROOT overlay, not a SnackBar.** Material's floating snack bar fades in over a fifth of its
  entrance behind a hard-clipped height wipe and accepts no curve; and a ScaffoldMessenger snack bar shows
  UNDER an open sheet's scrim. The root overlay sits above every route, sheet and dialog.
- One at a time: a new toast sends the last away. Dark in both themes (the inverse surface), rim and badge
  in the kind's colour, above the dock on a tab (`AppShell.dockClearance > 0`), above the keyboard when up.
- Hold: 4 s (Material's floor for no action) + 50 ms per character past 40, capped at 8 s; doubled under
  TalkBack. Swipe down or tap to dismiss. `liveRegion` announces it.
- An overlay entry sits under no `Material`: the toast wraps itself in one, or Text draws the debug style.

## Press feedback

Every overlay tappable is `ArulPressable`: the haptic on press-DOWN, a scale dip (0.98 rows, 0.97
buttons, 0.96 tiles) and a `pressed` flag the builder tints with the accent's own wash. Scale is a
transform — no layout, no layer. A press never changes a rim's WIDTH, and a tile you pick between
(apply target, language) keeps 1.5 in every state, so nothing shifts under the finger.

## Premium marks in app chrome

- `ArulMedallion` (gold ring, the paywall's medallion fill on light) around `GopuramArt` marks the ONE
  row that leads into the subscription (Need help? → Manage subscription): the owner asked for a more
  premium mark than the blocky `GopuramMark`, which stays only for marks under ~24 dp.
- `ArulCrest` (rules → floret → gopuram) heads every app dialog: the premium dialogs' ornament at app
  scale, in the ornaments' own antique gold on both themes.

## Measuring

`integration_test/overlay_perf_test.dart` times each overlay on a PROFILE build: the first open of each
apart (`overlay_cold_<theme>`: asset decode, first layout), then five warm opens and closes per kind
(`overlay_<kind>_<theme>`). Traps: [perf-measurement.md](perf-measurement.md).

```bash
flutter drive --profile --no-dds --device-user 0 -d <serial> \
  --driver=test_driver/perf_driver.dart --target=integration_test/overlay_perf_test.dart
```

The driver writes `build/<key>.json`. Read it against the panel's own budget (11.1 ms at 90 Hz), not
`flutter_test`'s default 16 ms. Nobody may touch the phone during a run. `flutter drive` uninstalls the
app it installed, and on a version-code downgrade it uninstalls the old build first: the phone loses
its signed-in test build. Layout across languages is the l10n matrix's job: every overlay, toast kinds
included, is a registry entry.
