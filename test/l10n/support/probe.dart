/// Pumps one screen at one locale in one configuration and collects EVERY
/// finding on the frame.
///
/// Collector, not first-failure. `tester.takeException()` surfaces one exception
/// and swallows the rest, and an `expect` inside the walk would stop at the
/// first bad paragraph — either way a screen with six broken strings reports one
/// and the next run "regresses" when you fix it. So [probeScreen] intercepts
/// `FlutterError.onError` for the duration of the pump, walks the whole render
/// tree afterwards, and returns everything it saw.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attribution.dart';
import 'envelope.dart';
import 'finding.dart';
import 'real_font_theme.dart';

/// What one pump saw.
class ProbeResult {
  const ProbeResult({
    required this.findings,
    required this.observedKeys,
    required this.measurements,
  });

  final List<Finding> findings;

  /// Every ARB key that actually reached a paragraph. A screen that renders
  /// nothing produces no findings and would otherwise pass silently — this is
  /// what the matrix asserts against, and what the ledger is built from.
  final Set<String> observedKeys;

  /// Every attributed paragraph that was measured, finding or not. The
  /// overflow findings carry no key, so this is what identifies the culprit.
  final List<Measurement> measurements;
}

/// Pumps the screen under [config] in [locale] and returns everything it saw.
///
/// [screen] is the registry id, used only for reporting.
Future<ProbeResult> probeScreen(
  WidgetTester tester, {
  required String screen,
  required String locale,
  required L10nConfig config,
  required Widget Function() build,
}) async {
  final findings = <Finding>[];
  final observedKeys = <String>{};
  final measurements = <Measurement>[];
  final overflowErrors = <FlutterErrorDetails>[];

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(config.width, config.height);
  addTearDown(tester.view.reset);

  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    // Overflow is reported as a FlutterError whose message names the direction
    // and the amount. Everything else on this channel (an image that cannot
    // load in a test, a missing plugin) is not this audit's business, and
    // failing on it would make the matrix a general-purpose smoke test.
    if (text.contains('overflowed by')) {
      overflowErrors.add(details);
    } else {
      previousOnError?.call(details);
    }
  };

  try {
    await tester.pumpWidget(build());
    // Bounded pumps, never pumpAndSettle: the skeleton gradient in
    // lib/app/widgets/skeleton.dart animates forever and would hang the suite.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 300));

    // Give every paragraph the family that matches its OWN final weight, then
    // re-lay-out, so an overflow caused by a post-theme `copyWith(fontWeight:)`
    // fires here rather than measuring narrow and passing.
    if (_realizeParagraphs(tester)) {
      await tester.pump();
      // That pump can rebuild a widget — the skeleton gradient, an entrance
      // animation, a progress row — and `RichText.updateRenderObject` would
      // then put the UN-realized span back. The restored style still names a
      // registered family (the theme supplied one), so the box-glyph guard
      // would not notice, and a w600 label would be measured against the w400
      // cut: narrower than the truth, i.e. a false PASS. So realize again and
      // require it to be a no-op.
      if (_realizeParagraphs(tester)) {
        throw StateError(
          'Spans un-realized themselves on $screen/$locale/${config.id}: a '
          'rebuild restored the app\'s own styles after the harness had '
          'pointed them at the per-weight faces. Every bold slot on this frame '
          'would measure narrow. See real_font_theme.dart.',
        );
      }
    }

    // One overflow, one finding. The same RenderFlex re-reports on every one of
    // the bounded pumps above (and again after the span realization), so
    // without this a single 16px overflow lands in the report six times and
    // makes the counts meaningless.
    final seenOverflows = <String>{};
    for (final details in overflowErrors) {
      final message = _firstLine(details.exceptionAsString());
      if (!seenOverflows.add(message)) continue;
      findings.add(
        Finding(
          kind: FindingKind.overflow,
          screen: screen,
          locale: locale,
          config: config.id,
          text: message,
          key: null,
          detail: message,
        ),
      );
    }

    findings.addAll(
      _walkParagraphs(
        tester,
        screen: screen,
        locale: locale,
        config: config,
        observedKeys: observedKeys,
        measurements: measurements,
      ),
    );
  } finally {
    FlutterError.onError = previousOnError;
  }

  return ProbeResult(
    findings: findings,
    observedKeys: observedKeys,
    measurements: measurements,
  );
}

/// Rewrites every laid-out paragraph's span so its style carries the real face
/// for its own weight. Returns true when anything changed.
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

List<Finding> _walkParagraphs(
  WidgetTester tester, {
  required String screen,
  required String locale,
  required L10nConfig config,
  required Set<String> observedKeys,
  required List<Measurement> measurements,
}) {
  final out = <Finding>[];
  final attributor = Attributor.of(locale);

  for (final object in tester.binding.renderViews.expand(_descendants)) {
    if (object is! RenderParagraph) continue;
    if (!object.hasSize || !object.attached) continue;

    final span = object.text;
    final rendered = span.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: false,
    );
    if (rendered.trim().isEmpty) continue;

    final key = attributor.attribute(rendered);
    // Server-authored content — a wallpaper or ringtone title in the fake data
    // — is out of scope (CLAUDE.md §6: only UI chrome is localized). Skipping
    // it here is why the fakes are allowed realistic-length titles.
    if (key == null) continue;

    final style = span.style;
    if (style != null && isUnrealizedStyle(style)) {
      // Box glyphs would make this measurement fiction. Fail rather than
      // measure — a false green is the worst outcome available.
      throw StateError(
        'Paragraph on $screen/$locale/${config.id} rendered with an '
        'unregistered family "${style.fontFamily}": "$rendered". '
        'The harness would be measuring box glyphs.',
      );
    }

    // Two ARB keys can share a rendered string. Attribution picks one; this
    // marker records that the pick was a guess, so the baseline subtraction
    // refuses to act on it (known_defects.dart).
    final ambiguity = attributor.isAmbiguous(rendered)
        ? ' $kAmbiguousMarker'
        : '';
    observedKeys.add(key);

    // An UNBOUNDED incoming constraint means the parent is measuring this
    // paragraph intrinsically and will size itself to whatever it asks for —
    // a FittedBox(scaleDown), an intrinsic-width column, a scrollable's
    // cross-axis. Such a paragraph cannot clip, and comparing its width against
    // its own intrinsic width is a tautology: the dock's three labels reported
    // "0.0% spare" on every configuration for exactly this reason, which is a
    // harness artifact, not a headroom warning. Only maxLines still applies.
    final bounded = object.constraints.maxWidth.isFinite;
    final available = bounded ? object.constraints.maxWidth : object.size.width;

    final painter = TextPainter(
      text: span,
      textAlign: object.textAlign,
      textDirection: object.textDirection,
      textScaler: object.textScaler,
      maxLines: object.maxLines,
      ellipsis: object.overflow == TextOverflow.ellipsis ? '…' : null,
      locale: object.locale,
      strutStyle: object.strutStyle,
      textWidthBasis: object.textWidthBasis,
      textHeightBehavior: object.textHeightBehavior,
    );

    try {
      painter.layout(maxWidth: available);
      final paintedHeight = painter.height;
      final lineCount = painter.computeLineMetrics().length;

      // Two verdicts, deliberately. `object.didExceedMaxLines` is what Flutter
      // ACTUALLY did to this paragraph in the frame that was just laid out —
      // authoritative about whether an ellipsis was painted. The independent
      // re-measure is the §3 check, and it is the one that can be wrong (a
      // reconstructed painter is not bit-identical to the render object's).
      // Taking the union means a reconstruction that misses a truncation cannot
      // hide a real one, and the disagreement itself is recorded so a harness
      // fidelity bug shows up as a note rather than as silence.
      final byRender = object.didExceedMaxLines;
      final byPainter = painter.didExceedMaxLines;
      final exceeded = byRender || byPainter;
      final disagreement = byRender != byPainter
          ? ' [re-measure disagreed: render=$byRender painter=$byPainter]'
          : '';

      // What the longest line actually needs, unwrapped. For a wrapping
      // paragraph this is naturally larger than the slot and means nothing, so
      // it is only consulted when wrapping is off or a maxLines cap is in play.
      painter.layout(maxWidth: double.infinity);
      final intrinsic = painter.width;
      final singleLine = !object.softWrap || object.maxLines == 1;

      measurements.add(
        Measurement(
          key: key,
          screen: screen,
          locale: locale,
          config: config.id,
          intrinsicWidth: intrinsic,
          laidOutWidth: available,
          height: paintedHeight,
          lines: lineCount,
        ),
      );

      if (exceeded) {
        out.add(
          Finding(
            kind: FindingKind.truncated,
            screen: screen,
            locale: locale,
            config: config.id,
            text: rendered,
            key: key,
            widgetChain: _chain(object),
            neededPx: singleLine ? intrinsic : available,
            availablePx: available,
            detail:
                'exceeded maxLines=${object.maxLines} '
                '(overflow: ${object.overflow.name})$disagreement$ambiguity',
          ),
        );
        continue;
      }

      if (bounded && singleLine && intrinsic > available + 0.01) {
        out.add(
          Finding(
            kind: FindingKind.clipped,
            screen: screen,
            locale: locale,
            config: config.id,
            text: rendered,
            key: key,
            widgetChain: _chain(object),
            neededPx: intrinsic,
            availablePx: available,
            detail: 'painted wider than the box it was given$ambiguity',
          ),
        );
        continue;
      }

      if (bounded && singleLine && available > 0) {
        final spare = (available - intrinsic) / available;
        if (spare >= 0 && spare < kHeadroomFraction) {
          out.add(
            Finding(
              kind: FindingKind.headroom,
              screen: screen,
              locale: locale,
              config: config.id,
              text: rendered,
              key: key,
              widgetChain: _chain(object),
              neededPx: intrinsic,
              availablePx: available,
              detail:
                  '${(spare * 100).toStringAsFixed(1)}% spare — an OEM Latin '
                  'face could take it',
            ),
          );
        }
      }
    } finally {
      painter.dispose();
    }
  }
  return out;
}

/// The nearest few ancestors, so a failure message points at a place in the
/// code rather than at "a Text somewhere".
String _chain(RenderObject object) {
  final parts = <String>[];
  RenderObject? node = object.parent;
  var depth = 0;
  while (node != null && depth < 5) {
    parts.add(node.runtimeType.toString());
    node = node.parent;
    depth++;
  }
  return parts.join(' ← ');
}

String _firstLine(String s) {
  final i = s.indexOf('\n');
  return i < 0 ? s : s.substring(0, i);
}
