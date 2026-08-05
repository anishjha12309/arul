# Task: Rebuild the Ringtones screen + floating dock to the design handoff

Read, in this order, before writing any code:
1. `CLAUDE.md` (repo rules — they all apply).
2. `design_handoff_ringtones_screen/README.md` — **the spec of record.** Every colour, size, radius, state table, SVG path, and animation timing lives there; this file deliberately repeats none of it. Where this file and the handoff disagree on visuals, the handoff wins. Where the handoff and CLAUDE.md disagree on behaviour, CLAUDE.md wins.
3. `design_handoff_ringtones_screen/Arul Ringtones.dc.html` — interactive reference. The `<script data-dc-script>` block at the bottom (`medallion()`, `motifEls()`, `buildRows()`) is the working implementation of the procedural cover art; port its logic, don't reinvent it.

## Mission

Recreate the handoff design pixel-for-pixel in Flutter, replacing the stale ringtones presentation and the stale dock. Three deliverables:

1. **Ringtones screen** — rework `lib/features/ringtones/presentation/ringtones_screen.dart` and `ringtone_states.dart` to the handoff: header + Earn chip, category chip row, ringtone row cards with all four state columns from the README's row-state table, procedural kolam-medallion cover art (a `CustomPainter`, seeded deterministically from the ringtone id per the README's State Management section), and the animated diya now-playing overlay (1100ms flicker; hold static with glow 0.4 when `MediaQuery.disableAnimations` is true).
2. **Floating dock** — the handoff dock **replaces** the existing `_ArulNavDock` design in `lib/app/shell/app_shell.dart`. The old dock (64px capsule, gliding solid-gold `AnimatedAlign` pill, label-only-when-active) is stale — remove it, don't blend it. New dock: three tabs (Wallpapers · Ringtones · Settings), all showing icon + label, active tab in the gold-tinted rounded cell, per the README's dock spec for both themes. Keep the shell's existing media refereeing (release video decoders when leaving wallpapers, stop ringtone preview when leaving ringtones). Update the commented-out `StatefulShellRoute` block in `lib/app/router.dart` to three branches (Settings becomes a branch) so it matches — but keep it commented.
3. **Layout correctness** — `extendBody: true`, list bottom inset ~120 so the last row clears the dock, chip row horizontally scrollable with no scrollbar, every loading/empty/error state also clearing the dock. Skeleton rows mirror the new row geometry.

## What is stale — remove it

- The old row/card design, `_CoverArt`, `_FallbackTile` (gold ♪ on silk), `_SetPill`, `_SettingsButton`, and any other presentation-layer widget the new design supersedes in `ringtones_screen.dart`.
- The old `_ArulNavDock` visual design (2 tabs, gliding pill).
- Do NOT remove: `ringtone_catalog_providers.dart`, `ringtone_preview_provider.dart`, `ringtone_set_provider.dart`, `ringtone_set_service.dart`, `cdn_ringtone_repository.dart`, the `_SetProgress` set-pipeline UX (restyle it into the new row if needed), or the premium gate. The new UI wires into all of these exactly as the old one did: `ensurePremium()` (awaiting the entitlement future) before Set, `ringtone_set_blocked_premium` tracking, preview via the shared player.

## Repo integration rules

- **Stay parked.** Preserve every `RINGTONES-PARKED` comment; the shell route and `WRITE_SETTINGS` stay commented. Everything must still compile and pass analysis.
- **Tokens:** map every handoff value that already exists in `lib/theme/arul_tokens.dart` to its token. Values the handoff introduces that are UI chrome (e.g. dock fill `#1B1215`, light now-playing title `#A3760F`, dock radius 26, row radius 15, cover radius 13) become new named roles in `ArulTokens`. The medallion painter's 10 gradient grounds and the `#EBD6A3` gold ink are artwork, not chrome — keep them as constants inside the painter file with a comment saying so. No `Color(0x…)` literals in screens; never grow `ArulColors`.
- **Category is the only browse axis** — keep the existing category-chip filtering behaviour; no All/New anywhere.
- **Earn chip** routes to the existing referral/earn entry point (`features/referral`), same destination the wallpapers feed uses.
- New user-visible strings (if any beyond what the ARBs already have) go through `gen_l10n` in all 6 locales. The 8 sample track titles are data, not chrome — they are not localized and not hardcoded into the screen (see verification).
- Haptics through the shared haptics layer wherever the wallpapers feature gives tap feedback. Analytics only via `AnalyticsService`.
- Play/Set visuals stay 34px/32px but hit targets expand to ≥44px, as the README requires.

## Verification — no device is available this session

I am away; work autonomously start to finish. Do not stop to ask questions — make routine judgment calls yourself and note them in the final report.

- `flutter gen-l10n && flutter analyze` clean, code formatted, `flutter test` green.
- The bucket has 0 ringtones, so the live screen would show only the empty state. Add a **debug-only preview path** (compile-time guarded, `kDebugMode` or a dart-define, clearly commented as dev-only next to a `RINGTONES-PARKED` marker) that lets a `flutter run` session open the redesigned screen inside the three-tab shell with the README's 8 sample tracks (Kolaru Pathigam playing) when the catalog is empty. This is how I will cross-verify on my phone later; it must be unreachable in release builds.
- Add widget tests for what a device can't be present to check: one-playing-row-at-a-time invariant (tapping a second row moves the state; tapping the playing row clears it and stops audio), category filtering, medallion determinism (same id → identical painter parameters), and Set still gated behind `ensurePremium()`.
- Do not build an `.aab`. Do not commit — I review first.

## Final report

Lead with what changed and what I should look at first when cross-verifying on device. Then: any handoff value that had no token and what you named it, any place the handoff was ambiguous and what you chose, and anything you could not verify without a device.
