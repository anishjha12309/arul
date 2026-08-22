// LAYER 2 — the same l10n matrix, on a real Android device.
//
//     flutter test integration_test -d emulator-5554
//
// Why a second layer at all: Layer 1 (`test/l10n/`) has no platform, so it has
// to SUPPLY the fonts and name them explicitly (see
// `test/l10n/support/load_real_fonts.dart`). Everything it measures therefore
// rests on the harness having reproduced Android's font resolution correctly.
// This layer removes that assumption — the faces, the fallback chain and the
// per-weight matching are the device's own, and the app's styles run exactly as
// they ship.
//
// THE AGREEMENT RULE (OVERNIGHT-L10N.md §3): both layers must report zero
// translation-induced findings over the same registry and envelope. A finding
// that appears HERE and not in Layer 1 is a Layer 1 fidelity bug — fix the
// harness, re-run Layer 1, re-derive the demotions. It is never a reason to
// weaken this file.
//
// The registry, the envelope, the probe and the English-baseline subtraction
// are all imported from Layer 1 rather than restated. Two copies would let a
// green run here "confirm" a result about a different screen.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/l10n/support/envelope.dart';
import '../test/l10n/support/finding.dart';
import '../test/l10n/support/known_defects.dart';
import '../test/l10n/support/probe.dart';
import '../test/l10n/support/real_font_theme.dart';
import '../test/l10n/support/registry.dart';

final List<Finding> _all = <Finding>[];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // The device brings its own fonts. Asking for `ArulUI600` here would name a
    // family Android has never heard of, and the point of this layer is to let
    // the platform resolve the stack itself.
    kUseHarnessFonts = false;
    await initRegistry();
  });

  tearDownAll(() {
    // No repo filesystem on the device — the findings travel out through
    // stdout, fenced so the runner can lift them cleanly.
    // ignore: avoid_print
    print('---LAYER2-FINDINGS-BEGIN---');
    // ignore: avoid_print
    print(jsonEncode(_all.map((f) => f.toJson()).toList()));
    // ignore: avoid_print
    print('---LAYER2-FINDINGS-END---');
  });

  for (final entry in kScreenRegistry) {
    group(entry.id, () {
      for (final locale in kLocales) {
        testWidgets(locale, (tester) async {
          installFakeChannels(tester.binding.defaultBinaryMessenger);

          final configs = <L10nConfig>[
            ...kGatingConfigs,
            ...kSweepConfigs,
            if (entry.textField) ...kKeyboardConfigs,
          ];

          final found = <Finding>[];
          final observed = <String>{};
          for (final config in configs) {
            final result = await probeScreen(
              tester,
              screen: entry.id,
              locale: locale,
              config: config,
              build: () =>
                  buildHarness(entry: entry, locale: locale, config: config),
            );
            found.addAll(result.findings);
            observed.addAll(result.observedKeys);
          }
          _all.addAll(found);

          if (entry.unlocalizedEnglish) {
            expect(observed, locale == 'en' ? isNotEmpty : isEmpty);
          } else {
            expect(observed, entry.textFree ? isEmpty : isNotEmpty);
          }

          final gatingIds = {
            for (final c in configs)
              if (c.gating) c.id,
          };
          final actionable = found
              .where(
                (f) =>
                    f.isFinding &&
                    gatingIds.contains(f.config) &&
                    !isKnownDefect(f),
              )
              .toList();

          expect(
            actionable,
            isEmpty,
            reason:
                '\nLAYER 2 found ${actionable.length} finding(s) on '
                '${entry.id} in $locale that Layer 1 did not:\n\n'
                '${actionable.map((f) => f.describe()).join('\n\n')}\n'
                '\nThis is a Layer 1 FIDELITY bug. Fix the harness, re-run '
                'Layer 1, re-derive demotions — do not relax this assertion.',
          );
        });
      }
    });
  }
}
