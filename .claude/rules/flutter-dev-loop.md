---
description: The Dart edit loop — analyzer, hot reload and runtime errors through the Dart MCP, not the CLI.
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
  - "integration_test/**/*.dart"
---

**`flutter analyze` takes ~5 minutes cold here** (measured on a clean tree), so an agent that runs
it per edit burns the session and one that skips it ships unanalysed code. Iterate on
`mcp__dart__analyze_files` instead — the same analysis server the IDE drives, already warm, back in
under a second. `flutter analyze` stays the phase gate, where its cost buys the whole-project
guarantee. `dart-analyze-gate.js` (Stop hook) holds the turn open if Dart was edited and neither ran.

- **Hot reload rather than relaunch.** After editing a widget or a method body under `lib/`, find
  the running app with the MCP `dtd` tool and call `hot_reload`. Use `hot_restart` when `main()`,
  `initState`, provider construction or any global/static state changed — a hot reload keeps the old
  state and the screen then lies about the change. Neither for edits under `test/`, nor for
  comment- or whitespace-only changes.
- **Dart exceptions come from `get_runtime_errors`** — no capture, no grep, no 256 KiB buffer race.
  Logcat is for native and system-side failures.
- **Run the narrow test file first** (`flutter test test/<area>/<name>_test.dart`); the whole suite
  belongs in the phase gate.
- `dart format` runs itself on every edit (`format-dart.js`) — never run it by hand.
- Generated files are TRACKED. Touch a `@riverpod`, `@freezed` or `@JsonSerializable` declaration
  and run build_runner, or every analyzer above reads a stale `*.g.dart`.

Device runs, logcat filters and UI driving: [on-device skill](../skills/on-device/SKILL.md).
