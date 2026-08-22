/// The canary, again — but inside whatever process is about to measure.
///
/// `font_canary_test.dart` proves the real faces load and that each weight
/// resolves to its own cut. It proves it in ITS OWN isolate: `flutter test`
/// runs every file in a separate process, so a green canary says nothing about
/// the process the matrix runs in. If the fonts failed to register only there —
/// a fixture deleted between runs, a path that resolves differently under a
/// different working directory, an SDK that changes `FontLoader` — the matrix
/// would measure box glyphs and pass, because box glyphs are WIDER than real
/// Latin and the English baseline it subtracts would be inflated to match.
///
/// So the matrix asserts it for itself, in `setUpAll`, before the first pump.
/// Cheap: two `TextPainter` layouts.
library;

import 'package:flutter/material.dart';

import 'load_real_fonts.dart';

/// Throws unless the real fonts are live in THIS process.
///
/// Two independent claims, the same two the standalone canary makes:
///   * a Tamil string measures as Noto Tamil rather than as the box face;
///   * w700 Latin measures wider than w400, which can only be true if the
///     per-weight static cuts are resolving.
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

  // The box face advances exactly 1em per character, so 4 Tamil letters would
  // measure 400.0 on the nose. Real Noto Tamil is nowhere near that.
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
