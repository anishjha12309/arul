// Reverts Phase 4 recheck edits that the independent reviewer rejected.
//
// Each entry names the locale, the key, and WHY the edit did not survive
// review. The `to` value must match the recheck report's `before` — the script
// checks that, so a revert cannot quietly invent a string.
//
//     dart run tools/l10n/revert_edits.dart --apply

import 'dart:convert';
import 'dart:io';

/// (locale, key) → why it is being reverted.
const _reverts = <(String, String, String)>[
  (
    'kn',
    'referEmpty',
    'WRONG. The edit swapped the borrowed noun "ಶೇರ್" for "ಹಂಚಿಕೆ", citing keys '
        'that all use the VERB ಹಂಚಿಕೊಳ್ಳು. This slot needs a noun, and ಹಂಚಿಕೆ in '
        'modern Kannada reads allocation/apportionment (ಸೀಟು ಹಂಚಿಕೆ), not "a '
        'share" — so a verbless fragment now reads "in one allocation, first '
        'friend". te/ml/hi all keep the transliteration in this exact key.',
  ),
  (
    'ta',
    'signInBody',
    'UNILATERAL. The dropped "across devices" clause is dropped in te/kn/ml/hi '
        'too; those four agents escalated it as a six-locale copy decision '
        'rather than fixing it. Applying it in Tamil alone would make Tamil the '
        'only locale promising cross-device sync. Reverted to keep the six in '
        'step; the four proposed wordings are in build/l10n_audit/recheck-*.json '
        'for the owner to apply everywhere at once.',
  ),
  (
    'ta',
    'uploadBody',
    'UNILATERAL. Same shape: "with the community" and "before it goes live" are '
        'absent from all five translations, and four agents escalated rather '
        'than fixed. Tamil alone would promise a pre-publication review the '
        'other four do not.',
  ),
  (
    'ta',
    'settingsNeedHelpSub',
    'UNSOUND JUSTIFICATION. The edit cited settingsSupport/settingsNeedHelp as '
        'precedent for translating "support", but those two translate "help" '
        '(உதவி) — and the edit then used a THIRD word (ஆதரவு) rather than the '
        'cited one. It also adds "குழு" (team), which the English does not say. '
        'De-transliterating சப்போர்ட் may still be right; it needs a Tamil '
        'speaker to pick the word, not this audit.',
  ),
];

void main(List<String> args) {
  final apply = args.contains('--apply');
  var done = 0;

  final byLocale = <String, List<(String, String)>>{};
  for (final (locale, key, why) in _reverts) {
    (byLocale[locale] ??= []).add((key, why));
  }

  for (final entry in byLocale.entries) {
    final locale = entry.key;
    final report =
        jsonDecode(
              File('build/l10n_audit/recheck-$locale.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final edits = (report['edits'] as List).cast<Map<String, dynamic>>();

    final arbPath = 'lib/app/l10n/app_$locale.arb';
    final arb =
        jsonDecode(File(arbPath).readAsStringSync()) as Map<String, dynamic>;

    for (final (key, why) in entry.value) {
      final edit = edits.firstWhere(
        (e) => e['key'] == key,
        orElse: () => throw StateError('no recorded edit for $locale/$key'),
      );
      final before = edit['before'] as String;
      final after = edit['after'] as String;
      if (arb[key] != after) {
        stderr.writeln(
          'SKIP $locale/$key — live value is not the edited one; '
          'it may have been demoted or changed since.',
        );
        continue;
      }
      arb[key] = before;
      done++;
      stdout.writeln('revert $locale/$key\n   why: $why\n');
    }

    if (apply) {
      File(arbPath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(arb)}\n',
      );
    }
  }

  stdout.writeln('$done revert(s) ${apply ? 'applied' : 'would apply'}');
}
