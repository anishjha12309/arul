// The owner's rule: a ringtone's name is shown WHOLE — never "…" and never a word split in half —
// at the widths and text scales this audience runs. Real Android fonts, because the test font
// measures ~2x wide and would prove nothing (load_real_fonts.dart). 360 dp is the audience's
// width; at 320 dp the title slot is ~70 dp and the longest name cannot fit at a legible size.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/envelope.dart';
import 'support/inline_canary.dart';
import 'support/load_real_fonts.dart';
import 'support/registry.dart';

void main() {
  setUpAll(() async {
    await loadRealFonts();
    assertRealFontsLive();
    await initRegistry();
  });

  final entry = kScreenRegistry.firstWhere((e) => e.id == 'ringtones.screen');
  final titles = kFakeRingtones.map((r) => r.title).toList();

  for (final (w, h) in const [(360.0, 640.0), (360.0, 720.0), (411.0, 860.0)]) {
    for (final scale in const [1.0, 1.3, 1.5]) {
      for (final locale in const ['en', 'ta', 'te', 'ml', 'hi']) {
        testWidgets('$locale ${w.toInt()}x${h.toInt()} @$scale', (
          tester,
        ) async {
          installFakeChannels(tester.binding.defaultBinaryMessenger);
          final config = L10nConfig(
            id: 'fit',
            width: w,
            height: h,
            textScale: scale,
            gating: false,
          );
          tester.view.physicalSize = Size(w, h);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            buildHarness(entry: entry, locale: locale, config: config),
          );
          await tester.pump(const Duration(milliseconds: 300));
          var checked = 0;
          for (final title in titles) {
            final finder = find.text(title);
            if (finder.evaluate().isEmpty) continue;
            final p = tester.renderObject<RenderParagraph>(finder.first);
            expect(p.didExceedMaxLines, isFalse, reason: '"$title" ellipsised');
            for (final word in title.split(' ')) {
              final painter = TextPainter(
                text: TextSpan(text: word, style: p.text.style),
                textScaler: p.textScaler,
                textDirection: TextDirection.ltr,
              )..layout();
              expect(
                painter.width,
                lessThanOrEqualTo(p.size.width + 0.5),
                reason: '"$word" of "$title" splits',
              );
              painter.dispose();
            }
            checked++;
          }
          expect(checked, greaterThan(0), reason: 'no title rendered');
        });
      }
    }
  }
}
