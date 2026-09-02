// The canary runs FIRST and is permanent -> every verdict in this directory is a width comparison.
// So the whole audit is worth exactly as much as the fonts behind it.
// Rot 1: the real faces stop loading and everything measures in FlutterTest box glyphs, a flat 1em per character.
// Rot 2: the per-weight static cuts stop resolving and every weight measures at 400 -> bold measures narrow.
// Both produce a GREEN matrix from fictional numbers -> the worst outcome available.
// Asserted per script against strict MONOTONICITY, never pinned pixels.
// An SDK that changes hinting by a hundredth of a pixel must not fail -> one that stops applying weight must.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/load_real_fonts.dart';
import 'support/real_font_theme.dart';

/// Bare consonants, no conjuncts and no combining marks -> the point is the FACE selected, not the shaping.
const _samples = <String, String>{
  'ta': 'வலபர',
  'te': 'వలపర',
  'kn': 'ವಲಪರ',
  'ml': 'വലപര',
  'hi': 'वलपर',
};

const _latin = 'Wallpapers';

double _width(
  String text, {
  String? family,
  List<String>? fallback,
  FontWeight weight = FontWeight.w400,
  String? locale,
  double size = 100,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: weight,
      ),
    ),
    textDirection: TextDirection.ltr,
    locale: locale == null ? null : Locale(locale),
  )..layout();
  final out = painter.width;
  painter.dispose();
  return out;
}

double _viaChain(String text, FontWeight weight, String locale) => _width(
  text,
  family: uiFamilyFor(weight),
  fallback: fallbackFor(weight),
  weight: weight,
  locale: locale,
);

const _weights = <FontWeight>[
  FontWeight.w400,
  FontWeight.w500,
  FontWeight.w600,
  FontWeight.w700,
];

void main() {
  setUpAll(loadRealFonts);

  group('real fonts are actually loaded', () {
    test('Latin is Roboto, not the box face', () {
      // The box face advances exactly 1em per character and Roboto's "Wallpapers" is under half that.
      // So anything close to the box width means the fixtures never loaded.
      const box = _latin.length * 100.0;
      final real = _viaChain(_latin, FontWeight.w400, 'en');
      expect(
        real,
        lessThan(box * 0.7),
        reason:
            'Latin measured ${real.toStringAsFixed(2)} against a box-glyph '
            'width of $box — the real faces did not load. Run: '
            'python tools/l10n/instance_fonts.py',
      );
      expect(real, greaterThan(box * 0.25));
    });

    for (final entry in _samples.entries) {
      test('${entry.key} renders real glyphs, not tofu', () {
        final real = _viaChain(entry.value, FontWeight.w400, entry.key);

        // Cinzel is a bundled Latin-only serif with none of these codepoints -> a live sample of "no glyph anywhere".
        // If the chain matched it, the script has no face behind it.
        final tofu = _width(
          entry.value,
          family: 'Cinzel',
          weight: FontWeight.w400,
          locale: entry.key,
        );
        expect(
          real,
          isNot(closeTo(tofu, 0.01)),
          reason:
              '${entry.key} measured ${real.toStringAsFixed(2)}, the same as '
              'the no-glyph control — the Indic fallback chain is not '
              'resolving and this script is being measured as tofu.',
        );

        const box = 4 * 100.0;
        expect(
          real,
          lessThan(box),
          reason: '${entry.key} is measuring at the box-glyph advance.',
        );
      });
    }

    test('the five scripts measure five different widths', () {
      // The sharpest tofu check available, and it needs no threshold -> every sample is four bare consonants.
      // A script falling through to the no-glyph face lands on exactly the notdef advance and collides with the others.
      // Five distinct widths therefore means five distinct real faces.
      final widths = <String, double>{
        for (final e in _samples.entries)
          e.key: _viaChain(e.value, FontWeight.w400, e.key),
      };
      expect(
        widths.values.map((w) => w.toStringAsFixed(2)).toSet(),
        hasLength(_samples.length),
        reason: 'scripts collapsed onto shared widths: $widths',
      );
      final tofu = _width(_samples['ta']!, family: 'Cinzel', locale: 'ta');
      for (final e in widths.entries) {
        expect(
          e.value,
          isNot(closeTo(tofu, 0.01)),
          reason: '${e.key} sits on the notdef advance ($tofu)',
        );
      }
    });
  });

  group('per-weight static instances resolve', () {
    test('Latin w700 is wider than w400 and every step is monotonic', () {
      final widths = [
        for (final w in [..._weights, FontWeight.w800])
          _viaChain(_latin, w, 'en'),
      ];
      for (var i = 1; i < widths.length; i++) {
        expect(
          widths[i],
          greaterThan(widths[i - 1]),
          reason:
              'Latin widths are not monotonic in weight: $widths. Either the '
              'variable font is loading at its default instance, or the '
              'per-weight families collapsed back into one.',
        );
      }
    });

    for (final entry in _samples.entries) {
      test('${entry.key} widths grow with weight', () {
        final widths = [
          for (final w in _weights) _viaChain(entry.value, w, entry.key),
        ];
        for (var i = 1; i < widths.length; i++) {
          expect(
            widths[i],
            greaterThan(widths[i - 1]),
            reason:
                '${entry.key} widths are not monotonic in weight: $widths. '
                'A FontLoader family with several cuts in it silently serves '
                'the first-registered face for every request — one family per '
                '(script, weight) is the only arrangement that holds.',
          );
        }
        expect(
          widths.last / widths.first,
          greaterThan(1.03),
          reason:
              '${entry.key} bold is only ${widths.last / widths.first}× '
              'regular — too flat to be a real weight axis.',
        );
      });
    }

    test('w800 Indic resolves to the 700 cut, as the device axis does', () {
      // Noto's wght axes stop at 700 -> a phone renders a w800 Indic slot at 700, and so must this.
      // Equality here is the assertion, never a tolerance.
      for (final entry in _samples.entries) {
        expect(
          _viaChain(entry.value, FontWeight.w800, entry.key),
          _viaChain(entry.value, FontWeight.w700, entry.key),
          reason: '${entry.key} w800 should clamp onto the 700 cut',
        );
      }
    });
  });

  group('the serif hands Indic to the fallback chain', () {
    // headlineSmall carries every screen title and is Marcellus, which is Latin-only.
    // On device the Tamil in it falls through to the system Noto -> the harness must reproduce that, not measure tofu.
    for (final entry in _samples.entries) {
      test('${entry.key} in a Marcellus slot matches the Noto face', () {
        final viaSerif = _width(
          entry.value,
          family: kSerifFamily,
          fallback: fallbackFor(FontWeight.w400),
          locale: entry.key,
        );
        expect(viaSerif, _viaChain(entry.value, FontWeight.w400, entry.key));
      });
    }

    test('Latin in a Marcellus slot stays Marcellus', () {
      final serif = _width(
        _latin,
        family: kSerifFamily,
        fallback: fallbackFor(FontWeight.w400),
        locale: 'en',
      );
      expect(serif, isNot(_viaChain(_latin, FontWeight.w400, 'en')));
    });
  });

  group('the style transform', () {
    test('is idempotent', () {
      const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
      final once = realizeTextStyle(style);
      final twice = realizeTextStyle(once);
      expect(twice.fontFamily, once.fontFamily);
      expect(twice.fontFamilyFallback, once.fontFamilyFallback);
    });

    test('routes weight to the matching family', () {
      expect(
        realizeTextStyle(
          const TextStyle(fontWeight: FontWeight.w700),
        ).fontFamily,
        uiFamilyFor(FontWeight.w700),
      );
      expect(
        realizeTextStyle(
          const TextStyle(fontWeight: FontWeight.w400),
        ).fontFamily,
        uiFamilyFor(FontWeight.w400),
      );
      expect(uiFamilyFor(FontWeight.w700), isNot(uiFamilyFor(FontWeight.w400)));
    });

    test('leaves bundled families alone but gives them a chain', () {
      final s = realizeTextStyle(
        const TextStyle(fontFamily: kSerifFamily, fontWeight: FontWeight.w400),
      );
      expect(s.fontFamily, kSerifFamily);
      expect(s.fontFamilyFallback, fallbackFor(FontWeight.w400));
    });

    test('every family it can emit is registered', () {
      for (final w in [
        FontWeight.w100,
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
        FontWeight.w800,
        FontWeight.w900,
      ]) {
        expect(kRegisteredFamilies, contains(uiFamilyFor(w)));
        for (final f in fallbackFor(w)) {
          expect(kRegisteredFamilies, contains(f));
        }
        expect(
          isUnrealizedStyle(realizeTextStyle(TextStyle(fontWeight: w))),
          isFalse,
        );
      }
    });
  });
}
