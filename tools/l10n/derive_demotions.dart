// Turns a recorded matrix run into the demotion set, and applies it.
//
// The exclusivity rule (OVERNIGHT-L10N.md §3): a key with at least one
// translation-induced finding in ANY locale at ANY gating configuration is
// removed from ALL FIVE non-English ARBs, so every user sees English for it.
// No per-locale mixing.
//
//     dart run tools/l10n/derive_demotions.dart          # report only
//     dart run tools/l10n/derive_demotions.dart --apply  # rewrite the ARBs
//
// Reads  build/l10n_audit/layer1-all.json + measurements-all.json
// Writes tools/l10n/demoted_translations.json (the archive, always)
//        lib/app/l10n/app_{ta,te,kn,ml,hi}.arb  (only with --apply)

import 'dart:convert';
import 'dart:io';

const _locales = ['ta', 'te', 'kn', 'ml', 'hi'];
const _findingsPath = 'build/l10n_audit/layer1-all.json';
const _measurementsPath = 'build/l10n_audit/measurements-all.json';
const _archivePath = 'tools/l10n/demoted_translations.json';

/// Keys that must never become English, whatever the matrix says (§3
/// "do-not-demote"). An overflowing endonym is a layout defect by definition.
///
/// It is empty, and that is a finding rather than an oversight: the six
/// language endonyms live in `_langs` in `language_sheet.dart` as hardcoded
/// constants, not in the ARBs, so they are structurally un-demotable. The set
/// stays here so the rule is enforced if a key is ever added.
const Set<String> kDoNotDemote = <String>{};

void main(List<String> args) {
  final apply = args.contains('--apply');

  final findings = _readList(_findingsPath, 'findings');
  final measurements = _readList(_measurementsPath, 'measurements');

  // Gating only. The 411dp sweep is report-only: fits-narrow-breaks-wide is a
  // layout defect, and demoting a translation would not fix it.
  bool gating(Map<String, dynamic> f) =>
      !(f['config'] as String).contains('sweep');

  // The English baseline, as signatures. Anything matching one of these fires
  // in English too and is therefore NOT translation-induced.
  final englishSignatures = <String>{
    for (final f in findings)
      if (f['locale'] == 'en' && f['kind'] != 'headroom') _signature(f),
  };

  final arbs = {
    for (final l in [..._locales, 'en']) l: _readArb(l),
  };

  final evidence = <String, List<Map<String, dynamic>>>{};

  for (final f in findings) {
    if (f['locale'] == 'en') continue;
    if (f['kind'] == 'headroom') continue;
    if (!gating(f)) continue;
    if (englishSignatures.contains(_signature(f))) continue;

    // Blame the string that grew, not the string that got squeezed.
    //
    // A truncation normally names its own culprit: the key that ran out of room
    // is the key whose translation is too long. But once a key has been demoted
    // it renders English everywhere, and if it STILL truncates in ta/te/ml the
    // width was taken by a sibling on the same screen — the Ringtones title goes
    // on truncating after demotion because the "Earn" pill beside it is what
    // grew. Demoting the victim a second time would achieve nothing, so a
    // finding on an already-English string is blamed the same way an overflow
    // is: by measurement, against the same key in English.
    final ownKey = f['key'] as String?;
    final alreadyEnglish =
        ownKey != null &&
        _rendersAsEnglish(ownKey, f['locale'] as String, arbs);
    final key = (f['kind'] == 'overflow' || alreadyEnglish)
        ? _blameOverflow(f, measurements)
        : ownKey;
    if (key == null) {
      stderr.writeln(
        'UNATTRIBUTED ${f['kind']} on ${f['screen']}/${f['locale']}/'
        '${f['config']} — reported, not demoted',
      );
      continue;
    }
    (evidence[key] ??= []).add({
      'locale': f['locale'],
      'screen': f['screen'],
      'config': f['config'],
      'kind': f['kind'],
      'px': f['overflow_px'] ?? 0,
      if (f['kind'] == 'overflow') 'blamed_via': 'largest growth vs en',
      'text': f['text'],
    });
  }

  for (final key in kDoNotDemote) {
    if (evidence.remove(key) != null) {
      stdout.writeln('do-not-demote: kept $key despite findings');
    }
  }

  // The archive is CUMULATIVE. Reaching the fixed point takes more than one
  // round — demoting a key changes the layout around it and can expose the
  // next culprit — and an archive that only held the last round would lose the
  // translations removed in the first, which is the one thing here that cannot
  // be reconstructed.
  final archiveFile = File(_archivePath);
  final archive = archiveFile.existsSync()
      ? (jsonDecode(archiveFile.readAsStringSync()) as Map)
            .cast<String, dynamic>()
      : <String, dynamic>{};
  final demoted = evidence.keys.toList()..sort();
  for (final key in demoted) {
    final ev = evidence[key]!;
    archive[key] = {
      'english': arbs['en']![key],
      'translations': {
        for (final l in _locales)
          if (arbs[l]!.containsKey(key)) l: arbs[l]![key],
      },
      'evidence': ev,
      // Worth knowing separately: a key that only breaks at the accessibility
      // font size is a candidate for selective restore if the bar ever moves.
      'only_failed_at_1_3': ev.every(
        (e) => (e['config'] as String).contains('@1.3'),
      ),
    };
  }

  File(_archivePath)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(archive),
      flush: true,
    );

  final only13 = archive.values
      .where((v) => (v as Map)['only_failed_at_1_3'] == true)
      .length;
  stdout.writeln('demoted: ${demoted.length}  (1.3-only: $only13)');
  for (final key in demoted) {
    final ev = evidence[key]!;
    final locales = ev.map((e) => e['locale']).toSet().toList()..sort();
    stdout.writeln('  $key  ${locales.join(',')}  (${ev.length} findings)');
  }

  if (!apply) {
    stdout.writeln('\n(report only — pass --apply to rewrite the ARBs)');
    return;
  }

  for (final locale in _locales) {
    final path = 'lib/app/l10n/app_$locale.arb';
    final text = File(path).readAsStringSync();
    final map = jsonDecode(text) as Map<String, dynamic>;
    var removed = 0;
    for (final key in demoted) {
      if (map.remove(key) != null) removed++;
      map.remove('@$key');
    }
    // Re-emit with the same shape gen_l10n and the repo already use: two-space
    // indent, UTF-8, trailing newline.
    File(
      path,
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(map)}\n');
    stdout.writeln('$path — removed $removed keys');
  }
}

String _signature(Map<String, dynamic> f) =>
    [f['kind'], f['screen'], f['config'], f['key'] ?? ''].join('|');

/// A `RenderFlex overflowed by 19 pixels on the bottom` names a box, not a
/// string, so the culprit has to be inferred — but from measurements, not from
/// a guess.
///
/// Every attributed paragraph on that screen was measured in this locale AND in
/// English at the same configuration. The string that broke the frame is the
/// one that grew — but WHICH growth matters depends on WHICH WAY the frame
/// broke, and getting that backwards blames the innocent.
///
/// **Bottom overflow** — a Column ran past the screen. The culprit is whatever
/// gained LINES: a translation that wraps from one line to two adds ~20px of
/// frame. Height, then width, break ties.
///
/// **Right overflow** — a Row ran past its width. Here extra lines are
/// *exculpatory*: a paragraph that wrapped is a paragraph the Row let shrink,
/// which is exactly what `Expanded`/`Flexible`/a wrapping `Text` does. The only
/// thing that can force a Row wider is a child that refuses to shrink — an
/// UNFLEXED `Text`, which stays on one line and demands its full intrinsic
/// width. So: rank by intrinsic-width growth, and DISCOUNT anything that gained
/// lines.
///
/// This distinction is not academic. Ranking right-overflows by lines (the
/// first version of this function did) blamed the longest wrapping body copy on
/// each screen and demoted eight keys — forty translations — that provably
/// could not have caused the frames they were blamed for: an `Expanded` child
/// cannot overflow its Row, and a chip inside a horizontally scrolling ListView
/// cannot overflow anything. The four real culprits were all unflexed header
/// titles (`uploadTitle`, `referTitle`, `remindersTitle`) or the one unflexed
/// sibling in a header Row (`earn`).
String? _blameOverflow(
  Map<String, dynamic> overflow,
  List<Map<String, dynamic>> measurements,
) {
  final screen = overflow['screen'];
  final locale = overflow['locale'];
  final config = overflow['config'];
  // A truncation is a horizontal problem by definition — a single-line title
  // ran out of width — so it is scored the same way a right-overflow is. Only
  // a "on the bottom" RenderFlex is vertical.
  final horizontal = !(overflow['text'] as String? ?? '').contains(
    'on the bottom',
  );

  final mine = <String, Map<String, dynamic>>{};
  final english = <String, Map<String, dynamic>>{};
  for (final m in measurements) {
    if (m['screen'] != screen || m['config'] != config) continue;
    if (m['locale'] == locale) {
      mine[m['key'] as String] = m;
    } else if (m['locale'] == 'en') {
      english[m['key'] as String] = m;
    }
  }
  if (mine.isEmpty) return null;

  String? best;
  var bestScore = 0.0;
  for (final entry in mine.entries) {
    final en = english[entry.key];
    if (en == null) continue;
    final dLines = (entry.value['lines'] as num) - (en['lines'] as num);
    final dHeight = (entry.value['height'] as num) - (en['height'] as num);
    final dWidth =
        (entry.value['intrinsic_width'] as num) -
        (en['intrinsic_width'] as num);
    final num score;
    if (horizontal) {
      // Width growth only, and a paragraph that gained lines is discounted to
      // nothing: it wrapped, so it did not force the Row wider.
      score = dLines > 0 ? -1 : dWidth;
    } else {
      // Lines dominate: one extra wrapped line is ~20 logical pixels of frame,
      // which is the scale of every vertical overflow recorded here.
      score = dLines * 1000 + dHeight * 10 + dWidth;
    }
    if (score > bestScore) {
      bestScore = score.toDouble();
      best = entry.key;
    }
  }
  return best;
}

List<Map<String, dynamic>> _readList(String path, String field) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('missing $path — run the full matrix with L10N_AUDIT_OUT');
    exit(1);
  }
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return (json[field] as List).cast<Map<String, dynamic>>();
}

Map<String, dynamic> _readArb(String locale) =>
    jsonDecode(File('lib/app/l10n/app_$locale.arb').readAsStringSync())
        as Map<String, dynamic>;

/// True when [key] already renders the English string in [locale] — either it
/// was demoted (absent, so gen_l10n back-fills the template) or the translation
/// is identical to English.
bool _rendersAsEnglish(
  String key,
  String locale,
  Map<String, Map<String, dynamic>> arbs,
) {
  final localeArb = arbs[locale];
  if (localeArb == null) return false;
  if (!localeArb.containsKey(key)) return true;
  return localeArb[key] == arbs['en']![key];
}
