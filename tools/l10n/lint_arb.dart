// Deterministic ARB linter — the half of "is this translation correct?" that
// needs no judgement.
//
//     dart run tools/l10n/lint_arb.dart              # table, exit 1 on ERROR
//     dart run tools/l10n/lint_arb.dart --json       # machine-readable
//
// It exists because the language review is the expensive, fallible half: a
// reviewer reading 800 strings will not notice that `{price}` became `{prize}`
// in Kannada, or that one Malayalam value is Tamil text pasted into the wrong
// file. Those are mechanical, so they are checked mechanically and never
// re-litigated by eye.
//
// **The rules are a pure function of the catalog** ([lintCatalog]) so
// `test/l10n/arb_lint_test.dart` can both run them on the real ARBs and plant a
// defect per rule and watch it fire. A linter nobody has seen fail is a linter
// nobody should trust — this one reported zero on its first green run, which is
// exactly when that matters.
//
// Severities: ERROR is a defect by construction and fails the run. WARN needs a
// human look and does not — failing on a class that has legitimate instances
// only teaches people to ignore the tool.
//
// The twin of this file lives in the Pakiza repo (11 locales, its own brands).
// Fix a rule in both.

import 'dart:convert';
import 'dart:io';

// ─── Configuration ────────────────────────────────────────────────────────────

class LintConfig {
  const LintConfig({
    required this.locales,
    required this.script,
    required this.brandsVerbatim,
    required this.brandsTransliterable,
    this.scriptExemptPrefixes = const [],
    this.templateLocale = 'en',
  });

  final String templateLocale;
  final List<String> locales;

  /// locale → the Unicode script its prose must be written in.
  final Map<String, String> script;

  /// Third-party marks that must survive VERBATIM, in Latin. A user hunting for
  /// the WhatsApp row needs to see the word WhatsApp, and transliterating
  /// someone else's trademark is not ours to do.
  final List<String> brandsVerbatim;

  /// Our own words, which a locale may legitimately transliterate — `appName`
  /// really is அருள்/అరుళ్/ಅರುಳ್/അരുൾ/अरुल, and `Premium` really is
  /// பிரீமியம்/ప్రీమియం/…
  ///
  /// So these are checked for CONSISTENCY, not for Latin. The locale's
  /// canonical rendering is not guessed: it is read off the key whose English
  /// value IS the token (`Arul` → appName, `Premium` → premiumTitle), and every
  /// other key mentioning the token must use that form or the Latin one. Two
  /// spellings of the product name inside one language is what this catches,
  /// and it is invisible to a reviewer reading keys one at a time.
  final List<String> brandsTransliterable;

  /// Key prefixes whose value is deliberately NOT in this file's language.
  ///
  /// A language picker shows each language in its own script — `langNameTa` is
  /// தமிழ் in the Punjabi file and in every other one, because that is what a
  /// Tamil speaker scanning the list looks for. So for these keys "wrong
  /// script", "no native script" and "identical to English" (`langNameEn` is
  /// English on purpose) are all the correct state, not defects.
  ///
  /// This is the one exemption in the linter, and it is narrow by design: it
  /// keyed off 63 real dandas and two endonyms producing 222 false ERRORs,
  /// which is how a tool gets switched off.
  final List<String> scriptExemptPrefixes;
}

/// This repo's catalog.
const kArulLintConfig = LintConfig(
  locales: ['ta', 'te', 'kn', 'ml', 'hi'],
  script: {
    'ta': 'Tamil',
    'te': 'Telugu',
    'kn': 'Kannada',
    'ml': 'Malayalam',
    'hi': 'Devanagari',
  },
  brandsVerbatim: ['WhatsApp', 'Google', 'UPI', 'PhonePe'],
  brandsTransliterable: ['Arul', 'Premium'],
);

const kArbDir = 'lib/app/l10n';

// ─── Script ranges ────────────────────────────────────────────────────────────

const kScriptRanges = <String, List<int>>{
  'Devanagari': [0x0900, 0x097F],
  'Bengali': [0x0980, 0x09FF],
  'Gurmukhi': [0x0A00, 0x0A7F],
  'Gujarati': [0x0A80, 0x0AFF],
  'Odia': [0x0B00, 0x0B7F],
  'Tamil': [0x0B80, 0x0BFF],
  'Telugu': [0x0C00, 0x0C7F],
  'Kannada': [0x0C80, 0x0CFF],
  'Malayalam': [0x0D00, 0x0D7F],
};

/// DANDA and DOUBLE DANDA. Unicode files them in the Devanagari block, but they
/// are the full stop for Gurmukhi, Bengali, Odia, Gujarati and Marathi alike —
/// so range-matching alone reports every properly punctuated Punjabi sentence
/// as "Devanagari text in a Gurmukhi string". Punctuation, not script.
const _sharedIndicPunctuation = {0x0964, 0x0965};

/// The script [rune] belongs to, or null for Latin, punctuation, digits, emoji.
String? scriptOf(int rune) {
  if (_sharedIndicPunctuation.contains(rune)) return null;
  for (final e in kScriptRanges.entries) {
    if (rune >= e.value[0] && rune <= e.value[1]) return e.key;
  }
  return null;
}

/// Indic digits render in a different numeral system from the rest of the UI,
/// which uses ASCII everywhere, so a stray one is a visible inconsistency.
bool isIndicDigit(int r) {
  for (final base in [
    0x0966,
    0x09E6,
    0x0A66,
    0x0AE6,
    0x0B66,
    0x0BE6,
    0x0C66,
    0x0CE6,
    0x0D66,
  ]) {
    if (r >= base && r <= base + 9) return true;
  }
  return false;
}

// ─── Findings ─────────────────────────────────────────────────────────────────

class Issue {
  Issue(this.severity, this.rule, this.locale, this.key, this.detail);
  final String severity; // ERROR | WARN
  final String rule;
  final String locale;
  final String key;
  final String detail;

  Map<String, dynamic> toJson() => {
    'severity': severity,
    'rule': rule,
    'locale': locale,
    'key': key,
    'detail': detail,
  };

  @override
  String toString() => '$severity $rule $locale/$key: $detail';
}

/// Every rule this linter can emit. The test asserts it can make each one fire,
/// so a rule that stops working cannot hide behind a green run.
const kRules = <String>[
  'placeholder-parity',
  'brace-balance',
  'icu-shape',
  'wrong-script',
  'no-native-script',
  'indic-digits',
  'brand-dropped',
  'brand-inconsistent',
  'identical-to-english',
  'whitespace-edge',
  'double-space',
  'tab',
  'newline-parity',
  'terminal-punctuation',
  'ellipsis-parity',
  'placeholder-spacing',
  'length-ratio',
  'unbalanced-quotes',
  'unbalanced-brackets',
  'orphan-key',
  'partial-demotion',
];

final _placeholderPattern = RegExp(r'\{(\w+)\}');

Set<String> placeholdersIn(String s) =>
    _placeholderPattern.allMatches(s).map((m) => m.group(1)!).toSet();

// ─── The rules ────────────────────────────────────────────────────────────────

/// Lints a whole catalog. Pure: no I/O, no globals.
List<Issue> lintCatalog(
  LintConfig cfg,
  Map<String, String> template,
  Map<String, Map<String, String>> byLocale,
) {
  final issues = <Issue>[];
  void err(String rule, String l, String k, String d) =>
      issues.add(Issue('ERROR', rule, l, k, d));
  void warn(String rule, String l, String k, String d) =>
      issues.add(Issue('WARN', rule, l, k, d));

  bool isPureBrand(String en) {
    var rest = en;
    for (final b in [...cfg.brandsVerbatim, ...cfg.brandsTransliterable]) {
      rest = rest.replaceAll(b, ' ');
    }
    return en.trim().isNotEmpty &&
        rest.replaceAll(RegExp(r'[\p{P}\p{S}\s]', unicode: true), '').isEmpty;
  }

  // Demotions are deliberate absences — gen_l10n back-fills English — so a key
  // absent from EVERY locale is fine. One absent from only some is not: five
  // users would see a translation and one English.
  final demotedEverywhere = <String>{
    for (final key in template.keys)
      if (byLocale.values.every((m) => !m.containsKey(key))) key,
  };

  // Each locale's own rendering of our brand words, read off the key whose
  // English value IS the token.
  final canonicalBrand = <String, Map<String, String>>{};
  for (final b in cfg.brandsTransliterable) {
    final anchor = template.entries
        .where((e) => e.value.trim() == b)
        .map((e) => e.key)
        .firstOrNull;
    if (anchor == null) continue;
    for (final locale in cfg.locales) {
      final v = byLocale[locale]?[anchor];
      if (v != null && v.trim().isNotEmpty) {
        (canonicalBrand[locale] ??= {})[b] = v.trim();
      }
    }
  }

  for (final locale in cfg.locales) {
    final map = byLocale[locale] ?? const <String, String>{};

    for (final key in map.keys) {
      if (!template.containsKey(key)) {
        err('orphan-key', locale, key, 'not in app_${cfg.templateLocale}.arb');
      }
    }
    for (final key in template.keys) {
      if (!map.containsKey(key) && !demotedEverywhere.contains(key)) {
        err(
          'partial-demotion',
          locale,
          key,
          'absent here but present in another locale — English everywhere or nowhere',
        );
      }
    }

    for (final entry in map.entries) {
      final key = entry.key;
      final tr = entry.value;
      final en = template[key];
      if (en == null) continue;

      // 1. Placeholder parity. A dropped `{price}` renders the sentence without
      //    the number; an invented one throws at runtime.
      final pe = placeholdersIn(en);
      final pt = placeholdersIn(tr);
      if (pe.length != pt.length || !pe.containsAll(pt)) {
        final missing = pe.difference(pt);
        final extra = pt.difference(pe);
        err(
          'placeholder-parity',
          locale,
          key,
          [
            if (missing.isNotEmpty) 'missing ${missing.join(",")}',
            if (extra.isNotEmpty) 'unknown ${extra.join(",")}',
          ].join('; '),
        );
      }

      // 2. Brace balance — an unclosed brace makes gen_l10n emit a broken
      //    message, or swallow the rest of the sentence.
      final open = '{'.allMatches(tr).length;
      final close = '}'.allMatches(tr).length;
      if (open != close) {
        err('brace-balance', locale, key, '$open "{" vs $close "}"');
      }

      // 3. ICU shape. If English selects or pluralizes and the translation does
      //    not, one branch silently disappears.
      for (final kw in ['plural,', 'select,']) {
        if (en.contains(kw) && !tr.contains(kw)) {
          err(
            'icu-shape',
            locale,
            key,
            'English uses $kw, translation does not',
          );
        }
      }

      // 4. Script hygiene. Two distinct defects: prose in the WRONG Indic
      //    script (a paste into the wrong file), and prose with no Indic script
      //    at all (never translated).
      final want = cfg.script[locale]!;
      final seen = <String>{};
      var indicDigits = 0;
      for (final r in tr.runes) {
        final s = scriptOf(r);
        if (s != null) seen.add(s);
        if (isIndicDigit(r)) indicDigits++;
      }
      final scriptExempt = cfg.scriptExemptPrefixes.any(key.startsWith);
      final foreign = seen.difference({want});
      if (foreign.isNotEmpty && !scriptExempt) {
        err(
          'wrong-script',
          locale,
          key,
          'contains ${foreign.join(",")} text in a $want string',
        );
      }
      if (seen.isEmpty && !isPureBrand(en) && !scriptExempt) {
        warn('no-native-script', locale, key, 'no $want characters at all');
      }
      if (indicDigits > 0) {
        warn('indic-digits', locale, key, '$indicDigits non-ASCII digit(s)');
      }

      // 5a. Third-party marks survive verbatim.
      for (final b in cfg.brandsVerbatim) {
        if (en.contains(b) && !tr.contains(b)) {
          err('brand-dropped', locale, key, '"$b" is not in the translation');
        }
      }

      // 5b. Our own words: one rendering per locale, not two.
      for (final b in cfg.brandsTransliterable) {
        if (!en.contains(b)) continue;
        final canonical = canonicalBrand[locale]?[b];
        if (canonical == null) continue;
        if (!tr.contains(b) && !tr.contains(canonical)) {
          err(
            'brand-inconsistent',
            locale,
            key,
            '"$b" is neither Latin nor this locale\'s form "$canonical"',
          );
        }
      }

      // 6. Untranslated.
      if (en == tr && !isPureBrand(en) && !scriptExempt) {
        warn(
          'identical-to-english',
          locale,
          key,
          'byte-identical to the template',
        );
      }

      // 7. Edge whitespace is STRUCTURE, not sloppiness, for the fragments a
      //    `Text.rich` stitches around an inline link: `uploadRightsPrefix`
      //    ends with the space before the link on purpose, and a translation
      //    that drops it runs the sentence straight into the link text. So this
      //    compares against English per side instead of forbidding it — losing
      //    a gap English has is the ERROR; inventing one is a WARN.
      //
      //    A fragment that is pure punctuation (English `uploadRightsSuffix` is
      //    just ".") carries no word boundary to compare against, so it is
      //    skipped rather than guessed at.
      final punctOnly = RegExp(r'[\p{P}\p{S}\s]', unicode: true);
      if (en.replaceAll(punctOnly, '').isNotEmpty) {
        final enLead = en != en.trimLeft();
        final trLead = tr != tr.trimLeft();
        final enTrail = en != en.trimRight();
        final trTrail = tr != tr.trimRight();
        if (enTrail && !trTrail) {
          err(
            'whitespace-edge',
            locale,
            key,
            'English ends with a space (the gap before an inline link); this does not',
          );
        }
        if (enLead && !trLead) {
          err(
            'whitespace-edge',
            locale,
            key,
            'English starts with a space; this does not',
          );
        }
        if (!enTrail && trTrail) {
          warn('whitespace-edge', locale, key, 'trailing space English lacks');
        }
        if (!enLead && trLead) {
          warn('whitespace-edge', locale, key, 'leading space English lacks');
        }
      }
      if (tr.contains('  ') && !en.contains('  ')) {
        warn('double-space', locale, key, 'double space');
      }
      if (tr.contains('\t')) err('tab', locale, key, 'contains a tab');

      // 8. Line structure is layout: a message the design lays out as two lines
      //    must not become one.
      final enLines = '\n'.allMatches(en).length;
      final trLines = '\n'.allMatches(tr).length;
      if (enLines != trLines) {
        warn(
          'newline-parity',
          locale,
          key,
          'English has $enLines newline(s), translation has $trLines',
        );
      }

      // 9. A body paragraph that loses its full stop next to five that keep
      //    theirs reads as truncated.
      bool endsSentence(String s) =>
          s.endsWith('.') ||
          s.endsWith('?') ||
          s.endsWith('!') ||
          s.endsWith('।');
      if (endsSentence(en) != endsSentence(tr)) {
        warn(
          'terminal-punctuation',
          locale,
          key,
          endsSentence(en)
              ? 'English ends a sentence, translation does not'
              : 'translation ends a sentence, English does not',
        );
      }

      // 10. "Loading…" without its ellipsis stops reading as in-progress.
      final enEll = en.endsWith('…') || en.endsWith('...');
      final trEll = tr.endsWith('…') || tr.endsWith('...');
      if (enEll != trEll) {
        warn('ellipsis-parity', locale, key, 'trailing ellipsis differs');
      }

      // 11. `{name}` glued to a word where English separated them is usually a
      //     lost space, not a grammar rule.
      //
      //     `\w` is ASCII-only in Dart, so a `\w`-based pattern matches nothing
      //     in any of the five scripts this rule exists for — it silently never
      //     fired until the self-test planted a case. Unicode letter/number
      //     classes, explicitly.
      for (final p in pe) {
        final re = RegExp(
          r'[\p{L}\p{N}]\{' + p + r'\}|\{' + p + r'\}[\p{L}\p{N}]',
          unicode: true,
        );
        if (re.hasMatch(tr) && !re.hasMatch(en)) {
          warn('placeholder-spacing', locale, key, '{$p} is glued to a word');
        }
      }

      // 12. Indic scripts run longer than English, but 3x is past any script
      //     difference and reliably means an explanation crept in.
      if (en.length >= 8 && tr.length > en.length * 3) {
        warn(
          'length-ratio',
          locale,
          key,
          '${(tr.length / en.length).toStringAsFixed(1)}x English '
              '(${en.length} → ${tr.length} chars)',
        );
      }

      // 13. Paired punctuation.
      if ('"'.allMatches(tr).length.isOdd) {
        warn('unbalanced-quotes', locale, key, 'odd number of "');
      }
      final ob = '('.allMatches(tr).length;
      final cb = ')'.allMatches(tr).length;
      if (ob != cb) {
        warn('unbalanced-brackets', locale, key, '$ob "(" vs $cb ")"');
      }
    }
  }

  return issues;
}

// ─── CLI ──────────────────────────────────────────────────────────────────────

Map<String, String> readArb(String dir, String locale) {
  final f = File('$dir/app_$locale.arb');
  if (!f.existsSync()) {
    stderr.writeln('missing ${f.path}');
    exit(2);
  }
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in json.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

void main(List<String> args) {
  const cfg = kArulLintConfig;
  final template = readArb(kArbDir, cfg.templateLocale);
  final byLocale = {for (final l in cfg.locales) l: readArb(kArbDir, l)};

  final issues = lintCatalog(cfg, template, byLocale);
  final errors = issues.where((i) => i.severity == 'ERROR').toList();
  final warns = issues.where((i) => i.severity == 'WARN').toList();

  if (args.contains('--json')) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'errors': errors.length,
        'warnings': warns.length,
        'issues': issues.map((i) => i.toJson()).toList(),
      }),
    );
  } else {
    final byRule = <String, List<Issue>>{};
    for (final i in issues) {
      (byRule[i.rule] ??= []).add(i);
    }
    for (final rule in byRule.keys.toList()..sort()) {
      final list = byRule[rule]!;
      stdout.writeln('\n${list.first.severity}  $rule  (${list.length})');
      for (final i in list) {
        stdout.writeln('    ${i.locale}/${i.key}: ${i.detail}');
      }
    }
    stdout.writeln(
      '\n${cfg.locales.length} locales · ${template.length} template keys',
    );
    stdout.writeln('${errors.length} error(s), ${warns.length} warning(s)');
  }

  exit(errors.isEmpty ? 0 : 1);
}
