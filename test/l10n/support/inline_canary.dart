/// The canary again, but inside whatever process is about to measure.
/// `font_canary_test.dart` proves the faces load in ITS OWN isolate -> `flutter test` runs every file separately.
/// So a green canary there says nothing about the process the matrix runs in.
/// Fonts failing to register only here would measure box glyphs and PASS.
/// Box glyphs are WIDER than real Latin -> the English baseline it subtracts inflates to match.
/// So the matrix asserts it for itself in `setUpAll`, before the first pump -> two `TextPainter` layouts.
library;

import 'package:flutter/material.dart';

import 'load_real_fonts.dart';

/// Throws unless the real fonts are live in THIS process -> two independent claims, as the standalone canary makes.
/// A Tamil string measures as Noto Tamil rather than as the box face.
/// w700 Latin measures wider than w400 -> that can only be true if the per-weight static cuts are resolving.
void assertRealFontsLive() {
  const tamil = 'வலபர';
  const latin = 'Wallpapers';

  double width(String text, FontWeight weight, String locale) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 100,
          fontWeight: weight,
          fontFamily: uiFamilyFor(weight),
          fontFamilyFallback: fallbackFor(weight),
        ),
      ),
      textDirection: TextDirection.ltr,
      locale: Locale(locale),
    )..layout();
    final out = painter.width;
    painter.dispose();
    return out;
  }

  // The box face advances exactly 1em per character -> 4 Tamil letters would measure 400.0 on the nose.
  // Real Noto Tamil is nowhere near that.
  final tamilWidth = width(tamil, FontWeight.w400, 'ta');
  if (tamilWidth >= 400 - 0.01) {
    throw StateError(
      'l10n matrix: Tamil measured ${tamilWidth.toStringAsFixed(2)}px at 100px '
      'font size — that is the FlutterTest box advance. The real Indic faces '
      'are not loaded in this process and every measurement would be fiction. '
      'Run: python tools/l10n/instance_fonts.py',
    );
  }

  final regular = width(latin, FontWeight.w400, 'en');
  final bold = width(latin, FontWeight.w700, 'en');
  if (!(bold > regular)) {
    throw StateError(
      'l10n matrix: Latin w700 (${bold.toStringAsFixed(2)}px) is not wider '
      'than w400 (${regular.toStringAsFixed(2)}px). The per-weight static cuts '
      'are not resolving, so every bold slot is being measured narrow — which '
      'passes real overflows. See test/l10n/support/load_real_fonts.dart.',
    );
  }
}
