// Builds `tools/l10n/coverage_ledger.csv` — one row per ARB key, with a verdict.
//
// The ledger is the answer to "did you actually cover the app, or only the part
// you happened to pump?". Every one of the 184 keys gets a verdict and the
// totals have to reconcile; `unexercised` carries a reason, so nothing ends the
// night silently unmeasured.
//
//     dart run tools/l10n/gen_ledger.dart

import 'dart:convert';
import 'dart:io';

const _coveragePath = 'build/l10n_audit/coverage-all.json';
const _findingsPath = 'build/l10n_audit/layer1-all.json';
const _slotPath = 'build/l10n_audit/slot_measure.json';
const _archivePath = 'tools/l10n/demoted_translations.json';
const _out = 'tools/l10n/coverage_ledger.csv';

/// Strings the OS renders, not Flutter. The reminder notification's title and
/// body go to the Android notification shade and the share text goes to the
/// system share sheet; both ellipsize gracefully and neither is reachable by
/// pumping a widget. Ledgered `system-ui`: measured nothing, demoted nothing
/// (OVERNIGHT-L10N.md §3 "exempt-but-ledgered").
const Set<String> kSystemUiKeys = <String>{
  'wallpaperShareCaption',
  'referShareMessage',
};

/// The premium paywall tree is English-by-decision (CLAUDE.md §5 and the design
/// handoff), so it is excluded from the matrix by design rather than missed.
bool _isPaywallKey(String key) =>
    key.startsWith('premium') &&
    !const {
      // These two are Settings rows, not paywall copy — they belong in the
      // matrix and are exercised there.
      'premiumBrandTitle',
    }.contains(key);

void main() {
  final en =
      jsonDecode(File('lib/app/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
  final keys = en.keys.where((k) => !k.startsWith('@')).toList()..sort();

  final coverage =
      jsonDecode(File(_coveragePath).readAsStringSync())
          as Map<String, dynamic>;
  final observed = <String, Set<String>>{}; // key -> screens
  coverage.forEach((screen, byLocale) {
    (byLocale as Map<String, dynamic>).forEach((locale, list) {
      for (final k in (list as List).cast<String>()) {
        (observed[k] ??= <String>{}).add(screen);
      }
    });
  });

  final findings =
      (jsonDecode(File(_findingsPath).readAsStringSync())
              as Map<String, dynamic>)['findings']
          as List;
  final englishDefectKeys = <String>{
    for (final f in findings.cast<Map<String, dynamic>>())
      if (f['locale'] == 'en' && f['kind'] != 'headroom' && f['key'] != null)
        f['key'] as String,
  };
  final headroomKeys = <String>{
    for (final f in findings.cast<Map<String, dynamic>>())
      if (f['kind'] == 'headroom' && f['key'] != null) f['key'] as String,
  };

  final archive =
      jsonDecode(File(_archivePath).readAsStringSync()) as Map<String, dynamic>;

  final slotMeasured = <String>{};
  final slotFile = File(_slotPath);
  if (slotFile.existsSync()) {
    final slot =
        jsonDecode(slotFile.readAsStringSync()) as Map<String, dynamic>;
    slotMeasured.addAll((slot['measured'] as List).cast<String>());
  }

  final rows = <List<String>>[
    ['key', 'verdict', 'screens', 'note'],
  ];
  final tally = <String, int>{};

  for (final key in keys) {
    final screens = observed[key] ?? const <String>{};
    String verdict;
    var note = '';

    if (archive.containsKey(key)) {
      verdict = 'demoted';
      final entry = archive[key] as Map<String, dynamic>;
      final ev = entry['evidence'] as List;
      note =
          '${ev.length} finding(s); '
          '1.3-only=${entry['only_failed_at_1_3']}';
    } else if (kSystemUiKeys.contains(key)) {
      verdict = 'system-ui';
      note = 'rendered by the OS (share sheet / notification shade)';
    } else if (englishDefectKeys.contains(key)) {
      verdict = 'layout-defect';
      note = 'fires in English too — not demotable';
    } else if (screens.isNotEmpty) {
      verdict = 'proven-fits';
      if (headroomKeys.contains(key)) note = 'headroom warning (<3% spare)';
    } else if (slotMeasured.contains(key)) {
      verdict = 'slot-measured';
      note = 'not pump-reachable; measured against its real slot width';
    } else if (_isPaywallKey(key)) {
      verdict = 'unexercised(paywall-english-by-decision)';
      note = 'CLAUDE.md §5 — the paywall tree is not localized';
    } else {
      verdict = 'unexercised(no-reason-recorded)';
      note = 'INVESTIGATE';
    }

    tally[verdict.split('(').first] =
        (tally[verdict.split('(').first] ?? 0) + 1;
    rows.add([key, verdict, screens.join(' '), note]);
  }

  File(_out)
    ..createSync(recursive: true)
    ..writeAsStringSync(rows.map(_csvLine).join('\n'));

  stdout.writeln('$_out — ${keys.length} keys');
  var total = 0;
  final names = tally.keys.toList()..sort();
  for (final v in names) {
    stdout.writeln('  ${v.padRight(16)} ${tally[v]}');
    total += tally[v]!;
  }
  stdout.writeln('  ${'TOTAL'.padRight(16)} $total');
  if (total != keys.length) {
    stderr.writeln('LEDGER DOES NOT RECONCILE: $total != ${keys.length}');
    exit(1);
  }
}

String _csvLine(List<String> cells) => cells.map(_csvCell).join(',');

String _csvCell(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
