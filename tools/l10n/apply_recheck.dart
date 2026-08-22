// Applies the Phase 4 translation-recheck edits to the ARBs.
//
// The five recheck agents report; they do not write. This applies what they
// found, and it REFUSES to apply an edit whose `before` does not match the live
// file byte-for-byte — an agent working from a stale read would otherwise
// silently overwrite a string it never saw.
//
// It also refuses any edit that changes the set of ICU placeholders. A recheck
// is allowed to fix a mistranslation; it is not allowed to break `{price}`.
//
//     dart run tools/l10n/apply_recheck.dart          # dry run
//     dart run tools/l10n/apply_recheck.dart --apply

import 'dart:convert';
import 'dart:io';

const _locales = ['ta', 'te', 'kn', 'ml', 'hi'];

void main(List<String> args) {
  final apply = args.contains('--apply');
  final placeholder = RegExp(r'\{(\w+)\}');
  var applied = 0;
  var flagged = 0;
  var refused = 0;

  for (final locale in _locales) {
    final reportFile = File('build/l10n_audit/recheck-$locale.json');
    if (!reportFile.existsSync()) {
      stderr.writeln('missing ${reportFile.path}');
      exit(1);
    }
    final report = jsonDecode(reportFile.readAsStringSync()) as Map;
    final edits = (report['edits'] as List).cast<Map<String, dynamic>>();
    flagged += (report['flagged'] as List).length;

    final arbPath = 'lib/app/l10n/app_$locale.arb';
    final arb =
        jsonDecode(File(arbPath).readAsStringSync()) as Map<String, dynamic>;

    for (final edit in edits) {
      final key = edit['key'] as String;
      final before = edit['before'] as String;
      final after = edit['after'] as String;
      final live = arb[key];

      if (live != before) {
        stderr.writeln(
          'REFUSED $locale/$key — `before` does not match the live file.\n'
          '  live:   ${jsonEncode(live)}\n'
          '  before: ${jsonEncode(before)}',
        );
        refused++;
        continue;
      }
      final wantPlaceholders = placeholder
          .allMatches(before)
          .map((m) => m[1])
          .toSet();
      final gotPlaceholders = placeholder
          .allMatches(after)
          .map((m) => m[1])
          .toSet();
      if (!_sameSet(wantPlaceholders, gotPlaceholders)) {
        stderr.writeln(
          'REFUSED $locale/$key — placeholders changed '
          '($wantPlaceholders -> $gotPlaceholders)',
        );
        refused++;
        continue;
      }
      if (before == after) {
        stderr.writeln('REFUSED $locale/$key — no-op edit');
        refused++;
        continue;
      }

      arb[key] = after;
      applied++;
      stdout.writeln(
        '$locale/$key  [${edit['category']}]\n'
        '   -  ${jsonEncode(before)}\n'
        '   +  ${jsonEncode(after)}\n'
        '   why: ${edit['reason']}',
      );
    }

    if (apply) {
      File(arbPath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(arb)}\n',
      );
    }
  }

  stdout.writeln(
    '\n$applied edit(s) ${apply ? 'applied' : 'would apply'}, '
    '$refused refused, $flagged flagged-for-human',
  );
  if (refused > 0) exit(2);
}

bool _sameSet(Set<String?> a, Set<String?> b) =>
    a.length == b.length && a.every(b.contains);
