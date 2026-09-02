// The ARB linter runs two ways -> on the REAL catalog it must report zero ERRORs, forever.
// And on a planted defect per rule, where each rule must fire -> that half is the load-bearing one.
// A linter nobody has seen fail is indistinguishable from one whose regex stopped matching.
// So every rule in `kRules` gets a catalog built to break exactly it.
// A rule with no such case FAILS the suite -> it never sits in the list merely looking implemented.

import 'package:flutter_test/flutter_test.dart';

import '../../tools/l10n/lint_arb.dart';

/// A miniature catalog in the same shape as the real one.
/// `appName` and `premiumTitle` are the brand anchors the linter reads canonical transliterations from -> always present.
({Map<String, String> template, Map<String, Map<String, String>> byLocale})
_catalog({
  Map<String, String> en = const {},
  Map<String, String> ta = const {},
}) {
  return (
    template: {'appName': 'Arul', 'premiumTitle': 'Premium', ...en},
    byLocale: {
      'ta': {'appName': 'அருள்', 'premiumTitle': 'பிரீமியம்', ...ta},
      'te': {'appName': 'అరుళ్', 'premiumTitle': 'ప్రీమియం'},
      'kn': {'appName': 'ಅರುಳ್', 'premiumTitle': 'ಪ್ರೀಮಿಯಂ'},
      'ml': {'appName': 'അരുൾ', 'premiumTitle': 'പ്രീമിയം'},
      'hi': {'appName': 'अरुल', 'premiumTitle': 'प्रीमियम'},
    },
  );
}

List<Issue> _lint({
  Map<String, String> en = const {},
  Map<String, String> ta = const {},
}) {
  final c = _catalog(en: en, ta: ta);
  return lintCatalog(kArulLintConfig, c.template, c.byLocale);
}

/// The rules a defect case is deliberately allowed to trip in passing.
/// Planting one defect often trips a second rule honestly -> Devanagari in a Tamil string has no Tamil in it either.
/// Asserting "only this rule fired" would force contrived cases that test less.
Matcher _fires(String rule) => contains(rule);

void main() {
  group('the real catalog', () {
    test('has zero ERRORs', () {
      final template = readArb(kArbDir, 'en');
      final byLocale = {
        for (final l in kArulLintConfig.locales) l: readArb(kArbDir, l),
      };
      final errors = lintCatalog(
        kArulLintConfig,
        template,
        byLocale,
      ).where((i) => i.severity == 'ERROR').toList();
      expect(
        errors,
        isEmpty,
        reason:
            '\n${errors.join('\n')}\n\n'
            'Run: dart run tools/l10n/lint_arb.dart',
      );
    });

    test('every locale is linted, not silently skipped', () {
      // A config naming a locale with no ARB file throws in readArb; one naming none passes vacuously -> pin the count.
      expect(kArulLintConfig.locales, hasLength(5));
      expect(
        kArulLintConfig.script.keys.toSet(),
        kArulLintConfig.locales.toSet(),
        reason: 'every locale needs a declared script or rule 4 skips it',
      );
    });
  });

  group('each rule fires on a planted defect', () {
    final fired = <String>{};
    List<String> rules(List<Issue> issues) {
      final r = issues.map((i) => i.rule).toList();
      fired.addAll(r);
      return r;
    }

    test('placeholder-parity — a dropped placeholder', () {
      expect(
        rules(
          _lint(
            en: {'k': 'Renews for {price} monthly'},
            ta: {'k': 'மாதம் புதுப்பிக்கப்படும்'},
          ),
        ),
        _fires('placeholder-parity'),
      );
    });

    test('placeholder-parity — an invented placeholder', () {
      expect(
        rules(
          _lint(
            en: {'k': 'Renews for {price}'},
            ta: {'k': '{prize} இல் புதுப்பிக்கப்படும்'},
          ),
        ),
        _fires('placeholder-parity'),
      );
    });

    test('brace-balance — an unclosed brace', () {
      expect(
        rules(_lint(en: {'k': 'Costs {price}'}, ta: {'k': '{price விலை'})),
        _fires('brace-balance'),
      );
    });

    test('icu-shape — a plural that lost its plural', () {
      expect(
        rules(
          _lint(
            en: {'k': '{n, plural, =1{1 day} other{{n} days}}'},
            ta: {'k': '{n} நாட்கள்'},
          ),
        ),
        _fires('icu-shape'),
      );
    });

    test('wrong-script — Devanagari inside a Tamil string', () {
      expect(
        rules(_lint(en: {'k': 'Settings'}, ta: {'k': 'सेटिंग्स'})),
        _fires('wrong-script'),
      );
    });

    test('no-native-script — prose left in Latin', () {
      expect(
        rules(
          _lint(en: {'k': 'Choose a category'}, ta: {'k': 'Choose a category'}),
        ),
        _fires('no-native-script'),
      );
    });

    test('indic-digits — a non-ASCII numeral', () {
      expect(
        rules(_lint(en: {'k': '7 days'}, ta: {'k': '௭ நாட்கள்'})),
        _fires('indic-digits'),
      );
    });

    test('brand-dropped — a third-party mark translated away', () {
      expect(
        rules(
          _lint(
            en: {'k': 'Share via WhatsApp'},
            ta: {'k': 'வாட்ஸ்அப் மூலம் பகிர்'},
          ),
        ),
        _fires('brand-dropped'),
      );
    });

    test('brand-inconsistent — a second spelling of our own product name', () {
      // A key rendering the brand differently from ta/premiumTitle is a split brand inside one language.
      expect(
        rules(_lint(en: {'k': 'Get Premium'}, ta: {'k': 'உயர்நிலை பெறு'})),
        _fires('brand-inconsistent'),
      );
    });

    test('identical-to-english — an untranslated value', () {
      expect(
        rules(_lint(en: {'k': 'Reminders'}, ta: {'k': 'Reminders'})),
        _fires('identical-to-english'),
      );
    });

    test('whitespace-edge — a trailing space English does not have', () {
      expect(
        rules(_lint(en: {'k': 'Retry'}, ta: {'k': 'மீண்டும் '})),
        _fires('whitespace-edge'),
      );
    });

    test('whitespace-edge — a LOST gap before an inline link is an ERROR', () {
      // `uploadRightsPrefix` ends with the space the link sits after -> dropping it runs the sentence into the link text.
      final issues = _lint(
        en: {'k': 'Uploading this violates our '},
        ta: {'k': 'இதைப் பதிவேற்றுவது எங்கள்'},
      );
      rules(issues);
      expect(
        issues.where((i) => i.rule == 'whitespace-edge').map((i) => i.severity),
        contains('ERROR'),
      );
    });

    test('whitespace-edge — a structural gap both sides keep is silent', () {
      final issues = _lint(
        en: {'k': 'Uploading this violates our '},
        ta: {'k': 'இதைப் பதிவேற்றுவது எங்கள் '},
      );
      expect(issues.map((i) => i.rule), isNot(contains('whitespace-edge')));
    });

    test('whitespace-edge — a pure-punctuation fragment is not compared', () {
      // English `uploadRightsSuffix` is "." and has no word boundary -> the Tamil continuation legitimately opens with a space.
      final issues = _lint(en: {'k': '.'}, ta: {'k': ' ஐ மீறுகிறது.'});
      expect(issues.map((i) => i.rule), isNot(contains('whitespace-edge')));
    });

    test('double-space', () {
      expect(
        rules(_lint(en: {'k': 'Try again'}, ta: {'k': 'மீண்டும்  முயற்சி'})),
        _fires('double-space'),
      );
    });

    test('tab', () {
      expect(
        rules(_lint(en: {'k': 'Retry'}, ta: {'k': 'மீண்டும்\tமுயற்சி'})),
        _fires('tab'),
      );
    });

    test('newline-parity — a two-line message flattened to one', () {
      expect(
        rules(
          _lint(
            en: {'k': 'This deletes your account.\n\nThere is no undo.'},
            ta: {'k': 'இது உங்கள் கணக்கை நீக்கும். மீட்க முடியாது.'},
          ),
        ),
        _fires('newline-parity'),
      );
    });

    test('terminal-punctuation — a lost full stop', () {
      expect(
        rules(
          _lint(
            en: {'k': 'Check your connection.'},
            ta: {'k': 'உங்கள் இணைப்பைச் சரிபார்க்கவும்'},
          ),
        ),
        _fires('terminal-punctuation'),
      );
    });

    test('ellipsis-parity — a lost ellipsis', () {
      expect(
        rules(_lint(en: {'k': 'Loading…'}, ta: {'k': 'ஏற்றுகிறது'})),
        _fires('ellipsis-parity'),
      );
    });

    test('placeholder-spacing — a placeholder glued to a word', () {
      expect(
        rules(
          _lint(
            en: {'k': 'Hello {name} there'},
            ta: {'k': 'வணக்கம்{name}நண்பரே'},
          ),
        ),
        _fires('placeholder-spacing'),
      );
    });

    test('length-ratio — an explanation that crept in', () {
      expect(
        rules(
          _lint(
            en: {'k': 'Set as ringtone'},
            ta: {
              'k':
                  'இந்த ஒலிக்கோப்பை உங்கள் தொலைபேசியின் அழைப்பு ஒலியாக '
                  'அமைக்க இங்கே தட்டவும் என்பதை நினைவில் கொள்ளவும் நன்றி',
            },
          ),
        ),
        _fires('length-ratio'),
      );
    });

    test('unbalanced-quotes', () {
      expect(
        rules(_lint(en: {'k': 'Say "hi"'}, ta: {'k': '"வணக்கம் என்று சொல்'})),
        _fires('unbalanced-quotes'),
      );
    });

    test('unbalanced-brackets', () {
      expect(
        rules(_lint(en: {'k': 'Free (for now)'}, ta: {'k': 'இலவசம் (இப்போது'})),
        _fires('unbalanced-brackets'),
      );
    });

    test('orphan-key — a key no longer in the template', () {
      expect(rules(_lint(ta: {'ghost': 'ஏதோ'})), _fires('orphan-key'));
    });

    test('partial-demotion — English in one locale, translated in another', () {
      // Present in ta and absent from the other four -> half the users see Tamil and half the English back-fill.
      // Demotion is all-or-nothing.
      expect(
        rules(_lint(en: {'k': 'Reminders'}, ta: {'k': 'நினைவூட்டல்கள்'})),
        _fires('partial-demotion'),
      );
    });

    // ── Negative cases ────────────────────────────────────────────────────
    // A rule that fires on correct input is worse than one that never fires -> it produces a wall nobody reads.
    // Both of these were real false-positive classes in Pakiza's catalog before the rules learned the difference.

    test('the Indic danda is punctuation, not Devanagari', () {
      // A correctly punctuated Punjabi, Bengali or Hindi sentence ends in U+0964, which Unicode files as Devanagari.
      final issues = _lint(
        en: {'k': 'Something went wrong. Please try again.'},
        ta: {'k': 'ஏதோ தவறு நடந்தது। மீண்டும் முயற்சிக்கவும்।'},
      );
      expect(issues.map((i) => i.rule), isNot(contains('wrong-script')));
    });

    test('an endonym is exempt only when the config says so', () {
      const en = {'langNameHi': 'हिंदी'};
      const ta = {'langNameHi': 'हिंदी'};
      final c = _catalog(en: en, ta: ta);

      // Without the exemption the endonym reads as Devanagari inside a Tamil file.
      expect(
        lintCatalog(kArulLintConfig, c.template, c.byLocale).map((i) => i.rule),
        contains('wrong-script'),
      );

      // With it, silence -> and nothing else is suppressed along the way.
      const exempting = LintConfig(
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
        scriptExemptPrefixes: ['langName'],
      );
      expect(
        lintCatalog(exempting, c.template, c.byLocale).map((i) => i.rule),
        isNot(contains('wrong-script')),
      );
    });

    test('the exemption does not spread to ordinary keys', () {
      const exempting = LintConfig(
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
        scriptExemptPrefixes: ['langName'],
      );
      final c = _catalog(
        en: {'settingsTitle': 'Settings'},
        ta: {'settingsTitle': 'सेटिंग्स'},
      );
      expect(
        lintCatalog(exempting, c.template, c.byLocale).map((i) => i.rule),
        contains('wrong-script'),
      );
    });

    tearDownAll(() {
      final never = kRules.toSet().difference(fired);
      expect(
        never,
        isEmpty,
        reason:
            'These rules are declared but no test made them fire, so nothing '
            'proves they still work: ${never.join(", ")}',
      );
    });
  });
}
