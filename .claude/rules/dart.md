---
description: Dart/Flutter conventions the analyzer cannot check — Riverpod 3 traps, widget perf, tests.
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
  - "integration_test/**/*.dart"
---

Style, strict typing and `const` are lint-enforced (`analysis_options.yaml`); `dart fix --apply` first.

- **A hidden widget's `ref.watch`/`ref.listen` is PAUSED.** Riverpod 3 pauses a Consumer under
  `TickerMode(enabled: false)`, which the shell sets on every hidden branch and Flutter sets on a
  page under an opaque pushed route. Work that must react off-screen listens above the shell.
- **Check `ref.mounted` after every `await` in a provider or Notifier** before touching `ref` or
  `state`: Riverpod 3 throws `UnmountedRefException` on a disposed Ref.
- **A provider reads; a write is a Notifier method called from the tap.** A side effect in a provider
  body can be skipped or repeated, and Riverpod 3 retries a failed provider by default (no `retry:`
  is set), so a POST in a body re-fires. Providers are top-level finals, never created per instance.
- Ephemeral state (selection, form, animation, any controller) lives in `State`, not a provider: a
  provider outlives the route, so Back shows the later page's state.
- Widget perf (Flutter docs): a reusable UI piece is a `StatelessWidget`, not a helper function;
  `setState`/`ref.watch` sit in the subtree that changes; the static subtree goes in
  `AnimatedBuilder.child`; long lists are `.builder`/slivers; no `operator ==` on a widget; no
  `Clip.antiAliasWithSaveLayer`. A new fade is `FadeTransition`, never an `Opacity` rebuilt per tick
  (the shell, `arul_sheet` and `confirm_dialog` fades are not precedent). `ShaderMask`, blur:
  [theming.md](theming.md).
- Tests use hand-written fakes and provider overrides; there is no mocking package.
- **Lints left OFF** — enable one only with every site fixed in the same change:
  `avoid_catches_without_on_clauses` (an `on` clause stops catching `Error`s), `discarded_futures`
  (its fix makes sync callbacks `async`), `avoid_redundant_argument_values` (flags deliberate design
  values; override false positives), `prefer_expression_function_bodies` (flags every one-`return`
  `build`), `unnecessary_async` (experimental; dropping `async` turns a failed Future into a throw).
