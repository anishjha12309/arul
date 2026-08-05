# Ringtones — parked 2026-07-29, un-parked 2026-08-05

> Historical record. The tab is LIVE again; nothing here is a current
> instruction. Live status and what is still owed:
> [known-issues.md](../../known-issues.md).

## Why it was parked

There was no ringtone audio in the bucket, so the tab could only ever render
"Ringtones are coming soon". Shipping a dead tab is worse than shipping no tab,
so the *entry point* was commented out and everything behind it left intact —
`features/ringtones/**`, `app/shell/app_shell.dart`, the models, every
`ringtone*` ARB key in all 6 locales, the worker's `catalog/ringtones/…` scope
and the `ringtones/` sweep prefix all still compiled and were still
type-checked. Dart simply tree-shook them out of the build.

That was verified rather than assumed: with `--print-instructions-sizes-to`
against the release APK, not one symbol from `features/ringtones/**`,
`app_shell.dart` or `arul_line_icons.dart` reached the AOT snapshot, and
`aapt2 dump permissions` showed no `WRITE_SETTINGS`.

## What un-parking changed (2026-08-05)

The owner reviewed the redesign on a device and asked for the tab permanently.

1. [lib/app/router.dart](../../../lib/app/router.dart) — the `StatefulShellRoute`
   is live: Wallpapers · Ringtones · Settings. **Settings moved INTO the dock**;
   it is a branch, not a route pushed over the feed, so the feed's header gear
   now `go`s to that branch instead of `push`ing a second copy. Its sub-screens
   (notifications, premium, refer, upload) stay top-level pushes over the shell.
2. [AndroidManifest.xml](../../../android/app/src/main/AndroidManifest.xml) —
   `WRITE_SETTINGS` is back. It exists **only** so `RingtoneManager` can set the
   device tone; without it every "Set" fails the `Settings.System.canWrite`
   check. It is special-access and shows on the Play listing, so the store form
   has to justify it.
3. The `/dev/*` shell and the "Ringtones preview (dev)" row in Settings are
   gone — the real route replaces them.

## The catalog filled the same day

30 tracks (30 s MP3, six categories) were imported on 2026-08-05, hours after
un-parking — so the "empty tab in a Play build" trade never actually reached a
release. Bulk imports run through
[tools/content-import/](../../../tools/content-import/) (`ringtones-plan.mjs`
→ `ringtones-import.mjs`).

The same change ported Pakiza's **pre-Android-10 set path**, which Arul had
never had: below API 29 a tone must be copied into the public Ringtones
directory and registered on the external MediaStore volume, behind a runtime
`WRITE_EXTERNAL_STORAGE` prompt. Contracts in
[edge-cases.md](../../edge-cases.md) §Ringtones.

## The sample rows that outlived the park — DELETED 2026-08-05

`lib/features/ringtones/dev/` existed only because an empty catalog made the
screen unreviewable on a device: it filled an **empty** catalog with the
handoff's eight sample tracks behind a compile-time
`kDebugMode || --dart-define=ARUL_RINGTONES_PREVIEW=true` guard, injecting at
the CATALOG provider so the chips and the filter saw the rows too. It was built
to self-retire once one real row existed, and it did — the directory and the
dart-define are both gone. Recover it from git if a future design review ever
needs a populated screen before its content exists.

## The dock

Rebuilt 2026-08-05 — three tabs, icon + label on every one, a 200ms crossfade
between branches. Shape, perf rules and branch refereeing:
**[../nav-dock.md](../nav-dock.md)**.

### The dock this replaced — historical only

[01](01-current-state.png) · [02](02-light-ringtones-active.png) ·
[03](03-dark-wallpapers-active.png) · [04](04-dark-ringtones-active.png) — a
physical device (1080×2392) at the parking commit. **Do not diff the new dock
against these.** The one thing they still prove: the dock is a detached floating
capsule with branch content running full-bleed behind it.
