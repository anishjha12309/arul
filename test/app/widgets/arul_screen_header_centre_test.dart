import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/theme/theme.dart';
import 'package:arul/app/widgets/arul_icon_tap.dart';
import 'package:arul/app/widgets/arul_line_icons.dart';
import 'package:arul/app/widgets/arul_screen_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../l10n/support/load_real_fonts.dart';
import '../../l10n/support/real_font_theme.dart';

const _dpr = 4.0;

// The gear is a filled round chip, so its ink centre is its box centre.
const _gearWidth = 60.0;

// Real fonts plus the system Noto fallback, as on the device (within ~1 dp).
// A type change that moves a script's titles off the gear fails here, not on a phone.
void main() {
  setUpAll(loadRealFonts);

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('${locale.languageCode} tab titles centre on the gear', (
      tester,
    ) async {
      final l = lookupAppLocalizations(locale);
      final en = lookupAppLocalizations(const Locale('en'));
      final offsets = <double>[];
      for (final (title, fallback) in [
        (l.headerWallpapers, en.headerWallpapers),
        (l.tabRingtones, en.tabRingtones),
        (l.headerStatus, en.headerStatus),
      ]) {
        offsets.add(await _titleOffset(tester, locale, title, fallback));
      }
      final mean = offsets.reduce((a, b) => a + b) / offsets.length;
      expect(
        mean.abs(),
        lessThan(0.75),
        reason:
            'mean title offset ${mean.toStringAsFixed(2)} dp from the gear '
            '(${offsets.map((o) => o.toStringAsFixed(2)).join(', ')}); '
            "retune ArulScreenHeader's per-script drop",
      );
    });
  }
}

/// Title ink centre minus gear centre, in dp: the mean of the ink box's middle and the ink's
/// weighted centre, so a lone matra or subscript counts but does not dominate.
Future<double> _titleOffset(
  WidgetTester tester,
  Locale locale,
  String title,
  String fallback,
) async {
  await tester.binding.setSurfaceSize(const Size(360, 120));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: applyRealFonts(ArulTheme.dark()),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            key: key,
            child: ArulScreenHeader(
              title: title,
              fallbackTitle: fallback,
              actions: [
                ArulIconTap.glyph(
                  glyph: ArulLineGlyph.settings,
                  label: 'Settings',
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final split = ((boundary.size.width - _gearWidth) * _dpr).round();
  final (data, w, h) = (await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: _dpr);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (bytes!, img.width, img.height);
  }))!;
  final titleCentre = _inkCentre(data, w, h, 0, split);
  final gear = _inkCentre(data, w, h, split, w);
  return (titleCentre - gear) / _dpr;
}

double _inkCentre(ByteData data, int w, int h, int x0, int x1) {
  int? top;
  var bottom = 0;
  var sum = 0.0;
  var weight = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = x0; x < x1; x++) {
      final a = data.getUint8((y * w + x) * 4 + 3);
      sum += a * (y + 0.5);
      weight += a;
      if (a > 96) {
        top ??= y;
        bottom = y;
      }
    }
  }
  return ((top! + bottom + 1) / 2 + sum / weight) / 2;
}
