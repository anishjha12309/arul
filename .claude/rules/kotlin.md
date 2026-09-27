---
description: Kotlin on the platform-channel side — threads, one reply, scope ownership, debug logs.
paths:
  - "android/app/src/**/*.kt"
  - "android/**/*.kts"
  - "android/gradle.properties"
---

The Kotlin side has no tests and no linter, and Dart sees only what crosses the channel, so a slip
here surfaces as a hung Future or a process death, never a compile error.

- **Handlers run on the main thread** (no channel uses a Task Queue), so file, bitmap and MediaStore
  work moves to the channel's `Dispatchers.IO` scope or an executor. Calls INTO Dart
  (`EventSink.success`, `invokeMethod`) go out on the main thread: off it, `FlutterJNI` throws.
- **Exactly one reply per call.** A second `success`/`error` throws "Reply already submitted"; a
  missing one leaves the Dart Future pending forever. Async paths guard with a `replied` flag
  (`ShareWatermarkChannel.finish`).
- **Catch inside every `launch` and executor task.** A throw inside `onMethodCall` itself reaches
  Dart as a `PlatformException`; the same throw in a coroutine or worker thread is uncaught, and
  Android kills the process.
- **A channel owns its `CoroutineScope(SupervisorJob() + …)` and cancels it in `dispose()`**; never
  `GlobalScope`. `WallpaperApplyChannel` is the one exception: the apply itself relaunches the
  Activity that disposes it, so its scope must survive.
- **No `!!`** (none in the tree) — `?:`, `?.let` or an early `result.error`.
- **`Log.d` only through the class's `logd`, gated on `BuildConfig.DEBUG`**: a filtered log still
  builds its string, and the gate is `false` in release. `Log.i`/`w`/`e` ship in release builds.
- **Channel and method names match only at runtime** — rename both sides together; a miss is a
  `MissingPluginException` or `notImplemented`, never a build error.
- Style is the Android Kotlin guide: `kotlin.code.style=official`, 4 spaces, new code wrapped at 100
  columns, no wildcard imports (`.editorconfig` carries it). Adding ktlint, detekt or a `lint {}`
  block touches the release build: owner's call.
