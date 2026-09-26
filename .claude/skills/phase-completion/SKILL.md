---
name: phase-completion
description: Checklist and workflow for completing a build phase in the Arul app. Use at the end of every phase to verify Definition of Done, run checks, and prepare for git commit.
---

# Phase Completion

Run at the end of every phase.

## 1. Checks — all must pass
```bash
dart run build_runner build --delete-conflicting-outputs   # generated files are TRACKED — stale
flutter analyze && flutter test                            # codegen commits clean and green
cd workers && npx tsc --noEmit && npx vitest run   # if workers/ touched
npx wrangler deploy                                 # if workers/ touched — deploy IS part of done
```
`gen_l10n` runs inside the flutter tool (`pubspec.yaml generate: true`), so ARBs need no separate
step — but `*.g.dart`/`*.freezed.dart` do, and nothing below catches them being stale.

## 2. Definition of Done
- [ ] `flutter analyze` clean; `dart format .` applied
- [ ] Loading / empty / error states on every async surface
- [ ] Edge cases handled with localized, user-visible messages (the docs/edge-cases.md contracts
      touching this phase)
- [ ] Tests green — premium/payments included, testable like everything else
- [ ] Analytics fire through `AnalyticsService`; update docs/analytics-events.md if events changed
- [ ] UI matches docs/ui-direction.md (tokens only — no literal colors), dark + light
- [ ] No secrets; config via `--dart-define-from-file`
- [ ] Device classes that FORK this change's code path were exercised — not all of them, the ones
      that fork. What forks in this app:

| Fork | Exercise when the change touches |
| --- | --- |
| Android ≤ 9 · ≤ 12 · 13+ · 16 | ringtone Set (pre-Q writes the public dir), notification permission (13+), predictive back (13–15 default off), edge-to-edge (enforced from 15) |
| low-RAM / 2-decoder SoC | the feed, any player, the auth video |
| large font scale + the 5 Indic locales | any string or fixed-height row (`configChanges` carries `fontScale`, so no restart hides an overflow) |
| gesture vs 3-button nav | anything anchored to the bottom — the dock, sheets, the wall |
| throttled cellular / offline | sign-in, checkout, `/geo`, catalog, push registration (on-device skill) |
| fresh install vs upgrade vs Play install | one-shot deferred links, prefs and token migration, `FLAG_SECURE`, QA tools |

## 3. Git — one commit per phase, NEVER before human approval
1. Show checks green + report against DoD.
2. Human validates on-device.
3. Only after explicit approval:
```bash
git add -A
git commit -m "<one line, plain phrasing, no attribution trailers>"
git push
```
Standing exception: a pubspec version bump auto-commits via `.claude/hooks/version-commit.js` — it
needs no approval and is not the phase commit. It runs `git add -A`, so it sweeps the WHOLE tree into
that `build <version>` commit, not just the pubspec — a bump has swept several unrelated files in
before now. Land the phase commit first, then bump. After a release build,
`release-commit-reminder.js` fires because an artifact is only reproducible if its source is in git;
that reminder still does not authorize committing without approval.

## Safety
- `.claude/hooks/guard-secrets.js` DENIES any `git add`/`commit` that names or stages `env/`,
  `*.keystore`, `*.jks`, `key.properties`, `google-services.json` or `.dev.vars`. A denial is the
  hook working — find what you staged, don't work around it.
- One phase = one commit = a known-good baseline.
