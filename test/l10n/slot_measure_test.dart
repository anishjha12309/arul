// The fallback for strings the matrix cannot reach by pumping.
// Some copy sits behind a state the harness cannot drive: a failed mail intent, a denied WRITE_SETTINGS, a festival.
// Leaving those unmeasured would make the ledger a statement about the harness rather than about the app.
// So they are measured directly -> same fonts, same locales, same envelope.
// A pumped screen gives its text a real slot; here there is none, and inventing one per key would be a guess.
// So the assertion is the one thing true regardless of layout -> an unbreakable TOKEN wider than the narrowest slot clips.
// No amount of wrapping can save it -> everything softer, total width and line count, is recorded but NOT asserted.
//
//     L10N_AUDIT_OUT=build/l10n_audit flutter test test/l10n/slot_measure_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/arb_index.g.dart';
import 'support/attribution.dart';
import 'support/envelope.dart';
import 'support/inline_canary.dart';
import 'support/load_real_fonts.dart';

/// The narrowest slot real content ever gets -> the 320dp gating width less the screen's own 16dp padding each side.
/// Anything wider at a gating text scale cannot be laid out without clipping or overflowing something.
const double kNarrowestContentSlot = 320 - 16 * 2;

/// The tightest text scale in the gating envelope.
const double kMaxGatingScale = 1.3;

void main() {
  setUpAll(() async {
    await loadRealFonts();
    assertRealFontsLive();
  });

  final unexercised = _unexercisedKeys();
  final measured = <String>[];
  final records = <Map<String, dynamic>>[];
  final tooWide = <String>[];

  test('every unexercised key is measured', () {
    expect(
      unexercised,
      isNotEmpty,
      reason:
          'No unexercised keys found. If the matrix now reaches everything '
          'that is good news, but check build/l10n_audit/coverage-all.json '
          'actually exists — a missing file would look the same.',
    );

    for (final key in unexercised) {
      for (final locale in kLocales) {
        final text = Attributor.stringsFor(locale)[key];
        if (text == null || text.trim().isEmpty) continue;

        final full = _width(text, locale);
        final widestToken = _widestToken(text, locale);
        records.add({
          'key': key,
          'locale': locale,
          'width_at_1_3': double.parse(full.toStringAsFixed(2)),
          'widest_token_px': double.parse(widestToken.px.toStringAsFixed(2)),
          'widest_token': widestToken.token,
          'slot': kNarrowestContentSlot,
        });
        if (widestToken.px > kNarrowestContentSlot) {
          tooWide.add(
            '$key/$locale: the token "${widestToken.token}" needs '
            '${widestToken.px.toStringAsFixed(1)}px in a '
            '${kNarrowestContentSlot.toStringAsFixed(0)}px slot — it cannot '
            'wrap out of trouble and will clip wherever it is placed',
          );
        }
      }
      measured.add(key);
    }

    expect(tooWide, isEmpty, reason: '\n${tooWide.join('\n')}\n');
  });

  tearDownAll(() {
    final out = Platform.environment['L10N_AUDIT_OUT'];
    if (out == null || out.isEmpty) return;
    final dir = Directory(out)..createSync(recursive: true);
    File('${dir.path}/slot_measure.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'slot_px': kNarrowestContentSlot,
        'text_scale': kMaxGatingScale,
        'measured': measured,
        'records': records,
      }),
    );
    stdout.writeln(
      'slot measure: ${measured.length} keys × ${kLocales.length} locales '
      '-> ${dir.path}/slot_measure.json',
    );
  });
}

/// Keys no pumped screen ever rendered, from the matrix's own coverage dump.
/// With no dump on disk every key is measured -> that is the safe direction.
List<String> _unexercisedKeys() {
  final all = kArbStrings['en']!.keys.toList()..sort();
  final file = File('build/l10n_audit/coverage-all.json');
  if (!file.existsSync()) return all;

  final coverage = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final seen = <String>{};
  for (final byLocale in coverage.values) {
    for (final list in (byLocale as Map<String, dynamic>).values) {
      seen.addAll((list as List).cast<String>());
    }
  }
  return all.where((k) => !seen.contains(k)).toList();
}

double _width(String text, String locale) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        // The app's most common body size, at the tightest gating scale.
        fontSize: 14,
        fontFamily: uiFamilyFor(FontWeight.w400),
        fontFamilyFallback: fallbackFor(FontWeight.w400),
      ),
    ),
    textDirection: TextDirection.ltr,
    textScaler: const TextScaler.linear(kMaxGatingScale),
    locale: Locale(locale),
  )..layout();
  final out = painter.width;
  painter.dispose();
  return out;
}

/// The widest unbreakable run in [text].
///
/// Splitting on whitespace is the right granularity for all six locales -> every one of them spaces its words.
/// None of these strings is a script that wraps mid-token.
/// A zero-width joiner or hard-space inside a token is what makes it unbreakable -> those are deliberately NOT split on.
({String token, double px}) _widestToken(String text, String locale) {
  var best = '';
  var bestPx = 0.0;
  // Newlines are real breaks; the ARB uses them deliberately.
  for (final token in text.split(RegExp(r'[ \t\n]+'))) {
    if (token.isEmpty) continue;
    // The button-weight cut -> a long token in a w600 label is the realistic worst case and is wider than at w400.
    final painter = TextPainter(
      text: TextSpan(
        text: token,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontFamily: uiFamilyFor(FontWeight.w600),
          fontFamilyFallback: fallbackFor(FontWeight.w600),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: const TextScaler.linear(kMaxGatingScale),
      locale: Locale(locale),
    )..layout();
    if (painter.width > bestPx) {
      bestPx = painter.width;
      best = token;
    }
    painter.dispose();
  }
  return (token: best, px: bestPx);
}
