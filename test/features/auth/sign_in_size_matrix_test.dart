// The sign-in wall on the phones people actually hold, in all six languages.
//
// The l10n matrix gates on the NARROW envelope (320dp/360dp) and one screen state. This one is the
// other axis: the eight logical sizes that cover most of the install base, every outcome the nudge
// can show, and the OS text scale on top. What it pins:
//
// The type on this screen is a FIXED size on every phone (owner's call) and the LAYOUT absorbs a
// translation that outgrows its slot — the ordinary way a shipped button behaves. So what this
// pins is the absorbing, not the fitting:
//
//   * **the subtitle WRAPS, within a budget** — at most TWO lines at text scale 1.0 and THREE at
//     1.3, in all six scripts, with the pill's `minHeight` growing to hold them. Past that the line
//     stops being a line under a button, so the copy is what gives.
//   * **the title stays ONE line** — it is a button label; `scaleDown` is how it absorbs a long
//     translation, and that is allowed at any scale.
//   * **nothing truncates and nothing overflows, at either scale** — no ellipsis on either line. A
//     nudge the user cannot finish reading is not a nudge, and half of these lines end in the verb.
//   * **the panel stays clear of both insets** — it is the only thing on the wall, it grows with the
//     copy and the text size, and there is no second control for it to collide with. These EIGHT
//     sizes are the bar.
//
// Real fonts, per weight, or every width here is fiction: `flutter test` renders one flat box glyph
// per character, which measures English ~2x too wide and Indic conjuncts at an advance they never
// take — a false PASS in both directions. See test/l10n/support/load_real_fonts.dart.

import 'package:arul/features/auth/domain/sign_in_outcome.dart';
import 'package:arul/features/auth/presentation/sign_in_screen.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../l10n/support/envelope.dart';
import '../../l10n/support/inline_canary.dart';
import '../../l10n/support/load_real_fonts.dart';
import '../../l10n/support/real_font_theme.dart';
import '../../l10n/support/registry.dart';

/// The top eight phone sizes in the install base, in logical dp.
/// Narrowest first — 360dp leaves the pill's lines ~180dp, and that is the binding case.
const _sizes = <(double, double)>[
  (360, 724),
  (360, 730),
  (360, 800),
  (360, 820),
  (384, 786),
  (384, 832),
  (384, 853),
  (392, 809),
];

/// 1.0 and 1.3 — the OS font sizes people actually run, same pair the l10n envelope gates on.
const _scales = <double>[1.0, 1.3];

/// How many lines the subtitle may take at each of those scales.
int _lineBudget(double scale) => scale > 1.0 ? 3 : 2;

/// Idle plus every failure the screen speaks to. `null` is idle.
const _states = <SignInOutcome?>[null, ...SignInOutcome.values];

void main() {
  setUpAll(() async {
    await loadRealFonts();
    assertRealFontsLive();
    await initRegistry();
  });

  for (final locale in kLocales) {
    testWidgets(locale, (tester) async {
      installFakeChannels(tester.binding.defaultBinaryMessenger);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final failures = <String>[];

      final entries = [
        for (final state in _states)
          ScreenEntry(
            id: 'signin.${state?.name ?? 'idle'}',
            build: () => SignInScreen(debugOutcome: state),
          ),
        // The launch held for the network: its wait line is a subtitle like the others.
        ScreenEntry(
          id: 'signin.waitingForInternet',
          build: () => const SignInScreen(debugWaitingForInternet: true),
        ),
      ];
      for (final entry in entries) {
        for (final (width, height) in _sizes) {
          for (final scale in _scales) {
            final config = L10nConfig(
              id: '${width.toInt()}x${height.toInt()}@$scale',
              width: width,
              height: height,
              textScale: scale,
              gating: true,
            );
            final where = '${entry.id} · $locale · ${config.id}';
            tester.view.physicalSize = Size(width, height);

            final overflows = <String>[];
            final previousOnError = FlutterError.onError;
            FlutterError.onError = (details) {
              final text = details.exceptionAsString();
              if (text.contains('overflowed by')) {
                overflows.add(_firstLine(text));
              } else {
                previousOnError?.call(details);
              }
            };
            try {
              await tester.pumpWidget(
                buildHarness(entry: entry, locale: locale, config: config),
              );
              // Bounded pumps, never pumpAndSettle -> the background player's placeholder animates.
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 32));
              // Give every paragraph the face carrying its own weight, then re-lay-out, so a w600
              // title is not measured against the w400 cut.
              if (_realizeParagraphs(tester)) await tester.pump();
            } finally {
              FlutterError.onError = previousOnError;
            }

            for (final message in overflows.toSet()) {
              failures.add('$where — $message');
            }

            // ── The title: ONE line, never truncated ───────────────────────────────────
            // It may be scaled down: that is a button label absorbing a long translation, and
            // `scaleDown` is the pill's own handling of it.
            final titleBox = tester.renderObject<RenderBox>(
              find.byKey(kSignInTitleKey),
            );
            final title = _descendants(
              titleBox,
            ).whereType<RenderParagraph>().single;
            if (title.didExceedMaxLines) {
              failures.add(
                '$where — the pill title was truncated: '
                '"${title.text.toPlainText()}"',
              );
            }

            // ── The subtitle: inside its line budget, never an ellipsis ────────────────
            final subtitle = tester.renderObject<RenderParagraph>(
              find.byKey(kSignInSubtitleKey),
            );
            if (subtitle.didExceedMaxLines) {
              failures.add(
                '$where — the pill subtitle was truncated: '
                '"${subtitle.text.toPlainText()}"',
              );
            }
            final lines = _lineCount(subtitle);
            final budget = _lineBudget(scale);
            if (lines > budget) {
              final painter = TextPainter(
                text: subtitle.text,
                textDirection: subtitle.textDirection,
                textScaler: subtitle.textScaler,
              )..layout();
              final need = painter.width;
              painter.dispose();
              failures.add(
                '$where — the subtitle took $lines lines at ${_px(subtitle)}, budget $budget: '
                'unwrapped it needs ${need.toStringAsFixed(1)}dp of a '
                '${subtitle.constraints.maxWidth.toStringAsFixed(0)}dp slot: '
                '"${subtitle.text.toPlainText()}". Shorten the line.',
              );
            }

            // ── The silk panel: it grows with the copy, so it must still fit the frame ─
            // It is centred and the only thing on the wall, so nothing can collide with it —
            // running off the top or the bottom is the one way the growth can go wrong.
            final panel = tester.getRect(find.byKey(kSignInPanelKey));
            if (panel.top < 0 || panel.bottom > height) {
              failures.add(
                '$where — the silk panel runs ${panel.top.toStringAsFixed(1)}dp to '
                '${panel.bottom.toStringAsFixed(1)}dp, outside a ${height.toStringAsFixed(0)}dp frame',
              );
            }
          }
        }
      }

      expect(
        failures,
        isEmpty,
        reason:
            '\n${failures.length} sign-in size finding(s):\n\n'
            '${failures.join('\n')}\n',
      );
    });
  }
}

/// The size the wall set this paragraph at, read back rather than hardcoded so a change of size
/// cannot leave a lying message.
String _px(RenderParagraph paragraph) =>
    '${paragraph.text.style?.fontSize?.toStringAsFixed(1) ?? '?'}px';

/// How many lines the paragraph actually took in its own slot.
/// `RenderParagraph` does not expose its line metrics, so re-lay-out its exact span at the width it
/// was given — the same re-measure the l10n probe does, for the same reason.
int _lineCount(RenderParagraph paragraph) {
  final painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  final lines = painter.computeLineMetrics().length;
  painter.dispose();
  return lines;
}

/// Rewrites every laid-out paragraph's span so its style carries the real face for its own weight.
/// Returns true when anything changed. Same trick as the l10n probe, for the same reason.
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

String _firstLine(String s) {
  final i = s.indexOf('\n');
  return i < 0 ? s : s.substring(0, i);
}
