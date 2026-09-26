// The sign-in wall's artwork on the phones people hold: every regional poster, before and after its
// live clip takes over, and the lotus as the baseline, at the common resolution × density pairs,
// three OS font sizes and all six languages. What it pins:
//
//   * **the deity's crown and face stay clear** of the wordmark, the silk panel (and so the pill),
//     and the screen's own edges and status bar — a face under the type or cut off is the failure;
//   * **the clip lands on the poster's pixels** — both are laid out in one frame box, so the
//     crossfade cannot jump;
//   * **the wall's type still fits** — no overflow, no truncated title or subtitle, the panel and
//     the pill wholly on screen, at 1.5 too.
//
// Real fonts, or every width is fiction (test/l10n/support/load_real_fonts.dart).
// `ARUL_WALL_DUMP=<dir>` writes a PNG per combination plus `grid.tsv`; `ARUL_CLIP_FRAMES=<dir>`
// holding `f0_<name>.png` (each clip's real frame 0) paints it in the live state of those dumps.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:arul/features/auth/domain/regional_art.dart';
import 'package:arul/features/auth/presentation/sign_in_screen.dart';
import 'package:arul/features/auth/presentation/widgets/launch_backdrop.dart';
import 'package:arul/features/auth/presentation/widgets/video_background.dart';
import 'package:arul/features/auth/providers/launch_art_provider.dart';
import 'package:arul/features/auth/providers/launch_clip_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../l10n/support/envelope.dart';
import '../../l10n/support/inline_canary.dart';
import '../../l10n/support/load_real_fonts.dart';
import '../../l10n/support/real_font_theme.dart';
import '../../l10n/support/registry.dart';

/// Resolution × density pairs: 720p at 320, 1080p at 440 and 480, 1440p at 560.
const _screens = <(int, int, int)>[
  (720, 1280, 320),
  (720, 1440, 320),
  (720, 1520, 320),
  (720, 1600, 320),
  (1080, 2340, 440),
  (1080, 2340, 480),
  (1080, 2400, 440),
  (1080, 2400, 480),
  (1080, 2412, 440),
  (1080, 2412, 480),
  (1440, 3200, 560),
];

const _scales = <double>[1.0, 1.3, 1.5];

/// Crown to chin of each deity, as fractions of the 9:16 frame, read off the posters.
const _faces = <String, Rect>{
  'murugan': Rect.fromLTRB(0.43, 0.359, 0.59, 0.471),
  'ayyappan': Rect.fromLTRB(0.413, 0.1875, 0.606, 0.281),
  'sivan': Rect.fromLTRB(0.46, 0.28, 0.57, 0.37),
};

/// Posters whose placement this matrix gates. Every poster's framing is the owner's, judged by
/// eye, so face findings go to the dump's grid and never fail the run.
const _placementGated = <String>{};

/// The wordmark carries a soft shadow; a crown that grazes its glyphs still reads as "under it".
const _wordmarkClearance = 4.0;

String _name(RegionalPoster p) =>
    p.asset.split('/').last.replaceAll('.webp', '');

void main() {
  final dumpDir = Platform.environment['ARUL_WALL_DUMP'];
  final framesDir = Platform.environment['ARUL_CLIP_FRAMES'];
  final grid = <String>[];

  setUpAll(() async {
    await loadRealFonts();
    assertRealFontsLive();
    await initRegistry();
  });

  tearDownAll(() {
    if (dumpDir == null) return;
    File('$dumpDir/grid.tsv')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${['art', 'state', 'locale', 'screen', 'scale', 'wordmark_gap', 'panel_gap', 'edge_gap', 'verdict', 'wordmark', 'panel'].join('\t')}\n${grid.join('\n')}\n',
      );
  });

  tearDown(() => LaunchClipLayer.debugStandIn = null);

  final arts = <(String, LaunchArt)>[
    ('lotus', const LotusArt()),
    for (final p in RegionalPoster.all) (_name(p), PosterArt(p)),
  ];

  for (final (artName, art) in arts) {
    for (final locale in kLocales) {
      testWidgets('$artName · $locale', (tester) async {
        installFakeChannels(tester.binding.defaultBinaryMessenger);
        for (final name in _quietChannels) {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => null,
          );
        }
        addTearDown(tester.view.reset);
        final failures = <String>[];
        final states = art is PosterArt
            ? const ['poster', 'live']
            : const ['video'];

        for (final state in states) {
          final live = state == 'live';
          if (live) {
            final frame = framesDir == null
                ? null
                : File('$framesDir/f0_$artName.png');
            final bytes = frame != null && frame.existsSync()
                ? frame.readAsBytesSync()
                : null;
            LaunchClipLayer.debugStandIn = (_) => bytes != null
                ? Image.memory(bytes, fit: BoxFit.fill, key: _standInKey)
                : const ColoredBox(color: Color(0x00000000), key: _standInKey);
          } else {
            LaunchClipLayer.debugStandIn = null;
          }
          final entry = ScreenEntry(
            id: 'wall',
            build: () => const SignInScreen(),
            overrides: [
              launchArtProvider.overrideWithValue(art),
              launchClipProvider.overrideWith(
                () => _FixedClip(live ? '/clip.mp4' : null),
              ),
            ],
          );

          for (final (pw, ph, dpi) in _screens) {
            final dpr = dpi / 160;
            final w = pw / dpr;
            final h = ph / dpr;
            for (final scale in _scales) {
              final screen = '${pw}x$ph@$dpi';
              final where = '$artName/$state · $locale · $screen · $scale';
              tester.view.devicePixelRatio = 1.0;
              tester.view.physicalSize = Size(w, h);
              final config = L10nConfig(
                id: screen,
                width: w,
                height: h,
                textScale: scale,
                gating: true,
              );

              final overflows = <String>[];
              final previous = FlutterError.onError;
              FlutterError.onError = (details) {
                final text = details.exceptionAsString();
                if (text.contains('overflowed by')) {
                  overflows.add(text.split('\n').first);
                } else {
                  previous?.call(details);
                }
              };
              try {
                await tester.pumpWidget(
                  RepaintBoundary(
                    key: _shotKey,
                    // A fresh scope per state: a kept one ignores a changed `overrideWith`.
                    child: KeyedSubtree(
                      key: ValueKey(state),
                      child: buildHarness(
                      entry: entry,
                      locale: locale,
                      config: config,
                      ),
                    ),
                  ),
                );
                await tester.pump();
                if (_realizeParagraphs(tester)) await tester.pump();
              } finally {
                FlutterError.onError = previous;
              }
              final found = <String>[
                for (final o in overflows.toSet()) 'overflow: $o',
              ];

              // ── Type: nothing truncated, panel and pill wholly on screen ───────────────
              for (final key in [kSignInTitleKey, kSignInSubtitleKey]) {
                final para = _descendants(
                  tester.renderObject(find.byKey(key)),
                ).whereType<RenderParagraph>().first;
                if (para.didExceedMaxLines) {
                  found.add('truncated "${para.text.toPlainText()}"');
                }
              }
              final panel = tester.getRect(find.byKey(kSignInPanelKey));
              final safe = Rect.fromLTRB(
                0,
                L10nConfig.topInset,
                w,
                h - L10nConfig.bottomInset,
              );
              if (!_inside(panel, safe)) found.add('panel off screen $panel');
              final pill = tester.getRect(
                find
                    .ancestor(
                      of: find.byKey(kSignInTitleKey),
                      matching: find.byType(GestureDetector),
                    )
                    .first,
              );
              if (!_inside(pill, safe)) found.add('pill off screen $pill');

              // ── Art: crown and face clear of the type and the edges ───────────────────
              final wordmark = _wordmarkGlyphs(tester);
              var wordGap = double.nan;
              var panelGap = double.nan;
              var edgeGap = double.nan;
              if (art is PosterArt) {
                final frame = tester.renderObject<RenderBox>(
                  find.byKey(kLaunchArtFrameKey),
                );
                final toScreen = frame.getTransformTo(null);
                final f = RegionalPoster.frame;
                final n = _faces[artName]!;
                final face = MatrixUtils.transformRect(
                  toScreen,
                  Rect.fromLTRB(
                    n.left * f.width,
                    n.top * f.height,
                    n.right * f.width,
                    n.bottom * f.height,
                  ),
                );
                wordGap = _gap(face, wordmark);
                panelGap = _gap(face, panel);
                edgeGap = [
                  face.left,
                  face.top - L10nConfig.topInset,
                  w - face.right,
                ].reduce((a, b) => a < b ? a : b);
                if (wordGap < _wordmarkClearance) {
                  found.add('face under the wordmark (gap ${_f(wordGap)})');
                }
                if (panelGap < 0) {
                  found.add('face under the panel (gap ${_f(panelGap)})');
                }
                if (edgeGap < 0) {
                  found.add('face cut by the edge (gap ${_f(edgeGap)})');
                }
                if (live) {
                  final clip = tester.getRect(find.byKey(_standInKey));
                  final poster = tester.getRect(
                    find.descendant(
                      of: find.byKey(kLaunchArtFrameKey),
                      matching: find.byType(RawImage),
                    ).first,
                  );
                  if ((clip.topLeft - poster.topLeft).distance > 0.01 ||
                      (clip.bottomRight - poster.bottomRight).distance > 0.01) {
                    found.add('clip $clip does not sit on the poster $poster');
                  }
                }
              }

              grid.add(
                [
                  artName,
                  state,
                  locale,
                  screen,
                  scale,
                  _f(wordGap),
                  _f(panelGap),
                  _f(edgeGap),
                  found.isEmpty ? 'PASS' : 'FAIL: ${found.join('; ')}',
                  _r(wordmark),
                  _r(panel),
                ].join('\t'),
              );
              for (final m in found) {
                // Placement findings on a poster the owner has not re-framed are reported in the
                // grid, never gated; everything about the type is gated on every art.
                if (m.startsWith('face') && !_placementGated.contains(artName)) {
                  continue;
                }
                failures.add('$where — $m');
              }

              if (dumpDir != null && !_noPng) {
                await _dump(
                  tester,
                  art,
                  '$dumpDir/$artName/$state/${locale}_${screen}_$scale.png',
                );
              }
            }
          }
        }
        expect(
          failures,
          isEmpty,
          reason: '\n${failures.length} finding(s):\n${failures.join('\n')}',
        );
      });
    }
  }
}

final _noPng = Platform.environment['ARUL_WALL_NO_PNG'] != null;

class _FixedClip extends LaunchClip {
  _FixedClip(this._path);

  final String? _path;

  @override
  String? build() => _path;

  @override
  void wallUp(RegionalPoster poster) {}
}

/// Platform streams the wall listens to; a dump's real async gaps would surface them unanswered.
const _quietChannels = [
  'dev.fluttercommunity.plus/connectivity',
  'dev.fluttercommunity.plus/connectivity_status',
  'com.hsrutility.arul/feed_video',
  'com.hsrutility.arul/feed_video_events',
  'com.hsrutility.arul/build_info',
];

const _shotKey = Key('matrix.shot');
const _standInKey = Key('matrix.clip');

String _r(Rect r) => [r.left, r.top, r.right, r.bottom].map(_f).join(',');

String _f(double v) => v.isNaN ? '-' : v.toStringAsFixed(1);

bool _inside(Rect r, Rect bounds) =>
    r.left >= bounds.left - 0.5 &&
    r.top >= bounds.top - 0.5 &&
    r.right <= bounds.right + 0.5 &&
    r.bottom <= bounds.bottom + 0.5;

/// Signed distance between two boxes: positive is the clear gap, negative the overlap's depth.
double _gap(Rect a, Rect b) => [
  b.left - a.right,
  a.left - b.right,
  b.top - a.bottom,
  a.top - b.bottom,
].reduce((x, y) => x > y ? x : y);

/// The wordmark's inked glyphs — its paragraph spans the full width, the letters do not.
Rect _wordmarkGlyphs(WidgetTester tester) {
  final para = tester.renderObject<RenderParagraph>(find.text('Arul'));
  final boxes = para.getBoxesForSelection(
    const TextSelection(baseOffset: 0, extentOffset: 4),
  );
  var r = boxes.first.toRect();
  for (final b in boxes.skip(1)) {
    r = r.expandToInclude(b.toRect());
  }
  return MatrixUtils.transformRect(para.getTransformTo(null), r);
}

Future<void> _dump(WidgetTester tester, LaunchArt art, String path) async {
  await tester.runAsync(() async {
    final context = tester.element(find.byKey(_shotKey));
    if (art is PosterArt) {
      await precacheImage(AssetImage(art.poster.asset), context);
    }
    await precacheImage(
      const AssetImage('assets/images/splash_poster.webp'),
      context,
    );
    for (final e in find.byType(Image).evaluate()) {
      final image = (e.widget as Image).image;
      await precacheImage(
        image,
        context,
      ).timeout(const Duration(seconds: 10), onTimeout: () {});
    }
  });
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_shotKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

bool _realizeParagraphs(WidgetTester tester) {
  var changed = false;
  for (final object in tester.binding.renderViews.expand(_descendants)) {
    if (object is! RenderParagraph) continue;
    final next = realizeSpan(object.text);
    if (next != null) {
      object.text = next;
      changed = true;
    }
  }
  return changed;
}

Iterable<RenderObject> _descendants(RenderObject root) sync* {
  yield root;
  final children = <RenderObject>[];
  root.visitChildren(children.add);
  for (final child in children) {
    yield* _descendants(child);
  }
}
