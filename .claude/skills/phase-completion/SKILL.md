---
name: phase-completion
description: Checklist and workflow for completing a build phase in the Arul app. Use at the end of every phase to verify Definition of Done, run checks, and prepare for git commit.
---

# Phase Completion

Run at the end of every phase (port-map phases included).

## 1. Checks — all must pass
```bash
flutter analyze && flutter test
cd workers && npx tsc --noEmit && npx vitest run   # if workers/ touched
npx wrangler deploy                                 # if workers/ touched — deploy IS part of done
```

## 2. Definition of Done
- [ ] `flutter analyze` clean; `dart format .` applied
- [ ] Loading / empty / error states on every async surface
- [ ] Edge cases handled with localized, user-visible messages (docs/edge-cases.md items for this phase)
- [ ] Tests green (skip tests for premium/payments/inactive features — project rule)
- [ ] Analytics fire through `AnalyticsService`; update docs/analytics-events.md if events changed
- [ ] UI matches docs/ui-direction.md (tokens only — no literal colors), dark + light
- [ ] No secrets; config via `--dart-define-from-file`

## 3. Git — one commit per phase, NEVER before human approval
1. Show checks green + report against DoD.
2. Human validates on-device.
3. Only after explicit approval:
```bash
git add -A
git status    # MUST NOT show: env/, *.keystore, key.properties, google-services.json
git commit -m "Phase <N>: <summary>"
git push
```

## Safety
- Eyeball `git status` before every commit — never stage secrets.
- One phase = one commit = a known-good baseline.
