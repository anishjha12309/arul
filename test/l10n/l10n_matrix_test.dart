// LAYER 1 — the permanent l10n overflow matrix.
//
// Every localized surface, in all six locales, across the gating envelope
// (320dp and 360dp, at text scale 1.0 and 1.3, each with real system chrome).
// It fails on any text that overflows, truncates or clips where English does
// not, and it joins `flutter test` forever.
//
// Read `support/load_real_fonts.dart` before touching anything here: these
// numbers are only real because the real Android faces are loaded, per weight.
// `font_canary_test.dart` is what stops that from rotting silently.
//
// Dump the raw findings (Phase 5 / Phase 7 consume exactly this):
//
//     L10N_AUDIT_OUT=build/l10n_audit flutter test test/l10n/l10n_matrix_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/arb_index.g.dart';
import 'support/envelope.dart';
import 'support/finding.dart';
import 'support/inline_canary.dart';
import 'support/known_defects.dart';
import 'support/load_real_fonts.dart';
import 'support/probe.dart';
import 'support/registry.dart';

final List<Finding> _all = <Finding>[];
final List<Measurement> _measurements = <Measurement>[];

/// screen id → locale → the ARB keys that actually reached a paragraph. This is
/// what the ledger's `proven-fits` verdict is built from: a key nothing ever
/// rendered is `unexercised`, and saying so is the difference between a matrix
/// that covers the app and one that only covers what it happened to pump.
final Map<String, Map<String, List<String>>> _coverage = {};

/// Locales to run. Defaults to all six; `L10N_ONLY=en` narrows it for the
/// English-baseline pass without editing the file.
List<String> get _locales {
  final only = Platform.environment['L10N_ONLY'];
  if (only == null || only.isEmpty) return kLocales;
  return only.split(',').map((s) => s.trim()).toList();
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    // In THIS process, not just in font_canary_test.dart's — every test file
    // gets its own isolate, so a green canary elsewhere proves nothing here.
    assertRealFontsLive();
    await initRegistry();
    _assertIndexInSync();
  });

  tearDownAll(() {
    final out = Platform.environment['L10N_AUDIT_OUT'];
    if (out == null || out.isEmpty) return;
    final dir = Directory(out)..createSync(recursive: true);
    final suffix = (Platform.environment['L10N_ONLY'] ?? 'all').replaceAll(
      ',',
      '-',
    );
    File(
      '${dir.path}/layer1-$suffix.json',
    ).writeAsStringSync(encodeFindings(_all));
    File(
      '${dir.path}/measurements-$suffix.json',
    ).writeAsStringSync(encodeMeasurements(_measurements));
    File(
      '${dir.path}/coverage-$suffix.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_coverage));
    stdout.writeln(
      'l10n audit: ${_all.length} records '
      '(${_all.where((f) => f.isFinding).length} findings) -> '
      '${dir.path}/layer1-$suffix.json',
    );
  });

  for (final entry in kScreenRegistry) {
    group(entry.id, () {
      for (final locale in _locales) {
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
            _measurements.addAll(result.measurements);
            // Coverage counts ONLY the gating configurations. The 411dp sweep
            // is report-only, and a taller/wider frame builds more of a lazy
            // ListView than 320dp does — five Settings rows (logout, delete
            // account, the three policy links) were credited "proven-fits" on
            // the strength of a config that can never produce a demotion, and
            // were then excluded from the slot-measure fallback for the same
            // reason. A verdict earned at 411dp is not a verdict about 320dp.
            if (config.gating) observed.addAll(result.observedKeys);
          }
          _all.addAll(found);
          _coverage.putIfAbsent(entry.id, () => {})[locale] = observed.toList()
            ..sort();

          if (entry.unlocalizedEnglish) {
            // The screen is hardcoded English. Pin the defect rather than
            // excuse it: its literals coincide with the English ARB, so `en`
            // attributes keys and no other locale does. Localizing the screen
            // makes this fail — which is the signal to delete the flag.
            expect(
              observed,
              locale == 'en' ? isNotEmpty : isEmpty,
              reason:
                  '${entry.id} is flagged unlocalizedEnglish. In $locale it '
                  'observed $observed. If this screen has been localized, '
                  'remove the flag from the registry; if it now renders '
                  'nothing at all, it stopped building.',
            );
          } else {
            // A screen that renders nothing produces no findings and would
            // pass. That is the quietest way for this matrix to go false-green
            // — a provider override that throws, a sheet that never opens, a
            // route that bails — so silence is a failure, not a pass.
            expect(
              observed,
              entry.textFree ? isEmpty : isNotEmpty,
              reason:
                  '${entry.id} rendered no localized text at all in $locale. '
                  'Either the screen did not build, or its strings are '
                  'hardcoded and therefore invisible to attribution.',
            );
          }

          // The sweep is report-only (§3): fits-narrow-breaks-wide is a layout
          // defect and demoting a translation would not fix it.
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
                '\n${actionable.length} l10n finding(s) on ${entry.id} '
                'in $locale:\n\n'
                '${actionable.map((f) => f.describe()).join('\n\n')}\n',
          );
        });
      }
    });
  }
}

/// The generated table has to describe the ARBs on disk, or every attribution
/// in this run points at the wrong key. Layer 1 can see the ARBs, so it checks.
void _assertIndexInSync() {
  for (final locale in kLocales) {
    final file = File('lib/app/l10n/app_$locale.arb');
    if (!file.existsSync()) continue;
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final onDisk = <String, String>{
      for (final e in json.entries)
        if (!e.key.startsWith('@') && e.value is String)
          e.key: e.value as String,
    };
    final indexed = kArbStrings[locale] ?? const <String, String>{};
    for (final e in onDisk.entries) {
      if (indexed[e.key] != e.value) {
        fail(
          'test/l10n/support/arb_index.g.dart is stale for $locale/${e.key}.\n'
          'Run: dart run tools/l10n/gen_arb_index.dart',
        );
      }
    }
    // And the other direction, which is the one this harness's own workflow
    // breaks: `derive_demotions --apply` REMOVES keys from the five translated
    // ARBs. A key still in the index but gone from disk leaves the attributor
    // holding a stale translation that shadows the English the app now renders
    // — so the paragraph attributes to nothing, is dropped from findings AND
    // from coverage, and the suite stays green while measuring less.
    for (final key in indexed.keys) {
      if (!onDisk.containsKey(key)) {
        fail(
          'test/l10n/support/arb_index.g.dart still holds $locale/$key, which '
          'is no longer in the ARB (demoted?).\n'
          'Run: dart run tools/l10n/gen_arb_index.dart',
        );
      }
    }
  }
}
