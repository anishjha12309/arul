// Builds the semantic-review workbook: one row per (locale, key) with
// everything a reviewer needs to judge it, and nothing they have to go looking
// for.
//
//     dart run tools/l10n/review_workbook.dart              # all keys
//     dart run tools/l10n/review_workbook.dart --risk       # claims only
//
// The deterministic linter (`lint_arb.dart`) already owns everything that can
// be decided mechanically. What is left is the half that cannot: does this
// Tamil sentence mean what the English sentence means, and does it read like
// something a person would write. That needs a reader — so this file's job is
// to make the reading efficient and auditable rather than to do it.
//
// ## Why `--risk` exists
//
// 180 keys x 5 locales is 900 judgements, and they are not equally consequential.
// A wrong "Retry" is a blemish. A wrong "you will not get another free trial"
// is a refund dispute, and a referral line that promises a reward the English
// never mentions is a claim the business has to honour. So the workbook can be
// narrowed to the keys that carry a FACTUAL CLAIM — money, time limits,
// permissions, legal terms, irreversible actions — and those get read first and
// most carefully.
//
// Output is JSON with an empty `verdict` per row, so a review is a diffable
// artifact rather than a conversation: `tools/l10n/review/<locale>.json`.

import 'dart:convert';
import 'dart:io';

const _arbDir = 'lib/app/l10n';
const _template = 'en';
const _locales = ['ta', 'te', 'kn', 'ml', 'hi'];
const _outDir = 'tools/l10n/review';

/// Substrings that mark a string as carrying a factual claim. Deliberately
/// over-inclusive: a false positive costs one extra read, a false negative
/// means the sentence that promises a refund never gets checked.
const _riskMarkers = <String>[
  // money and time
  '₹', 'price', 'month', 'day', 'free', 'trial', 'renew', 'refund', 'charge',
  'cancel', 'expire', 'billing', 'pay',
  // entitlement
  'premium', 'unlock', 'member', 'subscri',
  // irreversible / legal / permission
  'delete', 'remove', 'permanent', 'undo', 'lost', 'terms', 'privacy',
  'rights', 'copyright', 'permission', 'allow', 'review',
  // referral promises
  'refer', 'earn', 'reward', 'invite', 'friend',
];

bool _isRisk(String english) {
  final s = english.toLowerCase();
  return _riskMarkers.any(s.contains);
}

final _placeholder = RegExp(r'\{(\w+)\}');

Map<String, String> _readArb(String locale) {
  final f = File('$_arbDir/app_$locale.arb');
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in json.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

/// screen ids a key was seen rendering on, from the coverage ledger — so the
/// reviewer knows whether they are reading a button or a paragraph.
Map<String, String> _screens() {
  final f = File('tools/l10n/coverage_ledger.csv');
  if (!f.existsSync()) return const {};
  final out = <String, String>{};
  final lines = f.readAsLinesSync();
  for (final line in lines.skip(1)) {
    // key,verdict,screens,note — screens may be empty
    final parts = line.split(',');
    if (parts.length < 3) continue;
    out[parts[0]] = parts[2];
  }
  return out;
}

void main(List<String> args) {
  final riskOnly = args.contains('--risk');
  final template = _readArb(_template);
  final screens = _screens();

  Directory(_outDir).createSync(recursive: true);
  var total = 0;

  for (final locale in _locales) {
    final map = _readArb(locale);
    final rows = <Map<String, dynamic>>[];

    for (final entry in template.entries) {
      final key = entry.key;
      final en = entry.value;
      final tr = map[key];
      // Absent means demoted: the user sees English, and there is no
      // translation to judge.
      if (tr == null) continue;
      if (riskOnly && !_isRisk(en)) continue;

      rows.add({
        'key': key,
        'english': en,
        'translation': tr,
        'placeholders': _placeholder
            .allMatches(en)
            .map((m) => m.group(1))
            .toList(),
        'screens': screens[key] ?? '',
        'risk': _isRisk(en),
        // Filled in by the reviewer.
        'verdict': '', // ok | meaning | register | grammar | claim
        'note': '',
        'proposal': '',
      });
    }

    final path = '$_outDir/${riskOnly ? "risk-" : ""}$locale.json';
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'locale': locale,
        'template': _template,
        'count': rows.length,
        'rows': rows,
      }),
    );
    total += rows.length;
    stdout.writeln('$path — ${rows.length} rows');
  }

  stdout.writeln(
    '\n$total judgement(s) across ${_locales.length} locales'
    '${riskOnly ? " (claim-bearing keys only)" : ""}',
  );
}
