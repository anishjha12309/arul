/// What the matrix records.
library;

import 'dart:convert';

/// Why a string was recorded.
enum FindingKind {
  /// A RenderFlex / render-box overflow error fired while the frame was built.
  overflow,

  /// The paragraph ran past the maxLines it was given -> Flutter painted an ellipsis, faded it, or clipped it.
  truncated,

  /// The paragraph's own longest line is wider than the box it was laid out in.
  clipped,

  /// Fits, but with less than [kHeadroomFraction] of the slot to spare -> never a demotion.
  /// It is insurance against OEM Latin font substitution.
  headroom,

  /// A string the matrix could not reach by pumping -> measured directly against its real slot width instead.
  slotMeasured,
}

/// One recorded observation, immutable and JSON-round-trippable.
/// The verdict re-deriver reads the dumped artifacts rather than trusting this run.
class Finding {
  const Finding({
    required this.kind,
    required this.screen,
    required this.locale,
    required this.config,
    required this.text,
    this.key,
    this.widgetChain = '',
    this.neededPx = 0,
    this.availablePx = 0,
    this.detail = '',
  });

  final FindingKind kind;
  final String screen;
  final String locale;
  final String config;

  /// The offending string as rendered.
  final String text;

  /// The ARB key it was attributed to, or null when attribution failed -> a failure is itself reportable.
  final String? key;

  final String widgetChain;

  /// What the text needs and what it got -> `neededPx - availablePx` is the overflow in logical pixels.
  final double neededPx;
  final double availablePx;

  final String detail;

  double get overflowPx => neededPx - availablePx;

  bool get isFinding => kind != FindingKind.headroom;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'screen': screen,
    'locale': locale,
    'config': config,
    'text': text,
    if (key != null) 'key': key,
    if (widgetChain.isNotEmpty) 'widget_chain': widgetChain,
    'needed_px': double.parse(neededPx.toStringAsFixed(2)),
    'available_px': double.parse(availablePx.toStringAsFixed(2)),
    'overflow_px': double.parse(overflowPx.toStringAsFixed(2)),
    if (detail.isNotEmpty) 'detail': detail,
  };

  static Finding fromJson(Map<String, dynamic> j) => Finding(
    kind: FindingKind.values.firstWhere((k) => k.name == j['kind']),
    screen: j['screen'] as String,
    locale: j['locale'] as String,
    config: j['config'] as String,
    text: j['text'] as String,
    key: j['key'] as String?,
    widgetChain: (j['widget_chain'] as String?) ?? '',
    neededPx: (j['needed_px'] as num?)?.toDouble() ?? 0,
    availablePx: (j['available_px'] as num?)?.toDouble() ?? 0,
    detail: (j['detail'] as String?) ?? '',
  );

  /// The line a failing test prints -> screen, locale, configuration, string and margin, enough to reproduce by hand.
  String describe() {
    final where = '$screen · $locale · $config';
    final what = key == null ? '"${_clip(text)}"' : '$key = "${_clip(text)}"';
    final by = kind == FindingKind.overflow
        ? detail
        : 'needs ${neededPx.toStringAsFixed(1)}px in '
              '${availablePx.toStringAsFixed(1)}px '
              '(over by ${overflowPx.toStringAsFixed(1)}px)';
    return '[${kind.name}] $where\n    $what\n    $by'
        '${widgetChain.isEmpty ? '' : '\n    in $widgetChain'}';
  }

  static String _clip(String s) {
    final flat = s.replaceAll('\n', '⏎');
    return flat.length <= 70 ? flat : '${flat.substring(0, 67)}…';
  }

  @override
  String toString() => describe();
}

/// One measured paragraph, finding or not.
/// Overflow findings carry no ARB key -> `RenderFlex overflowed by 19 pixels` names a box, not a string.
/// These records identify the culprit without guessing.
/// The key responsible is the one whose translation grew most against the English measurement of the SAME key.
/// Same screen, same configuration.
class Measurement {
  const Measurement({
    required this.key,
    required this.screen,
    required this.locale,
    required this.config,
    required this.intrinsicWidth,
    required this.laidOutWidth,
    required this.height,
    required this.lines,
  });

  final String key;
  final String screen;
  final String locale;
  final String config;

  /// The longest line, unwrapped.
  final double intrinsicWidth;

  /// The slot it was given.
  final double laidOutWidth;

  /// Painted height in the slot, and how many lines it took -> a translation that gains a line pushes a sheet off screen.
  final double height;
  final int lines;

  Map<String, dynamic> toJson() => {
    'key': key,
    'screen': screen,
    'locale': locale,
    'config': config,
    'intrinsic_width': double.parse(intrinsicWidth.toStringAsFixed(2)),
    'laid_out_width': double.parse(laidOutWidth.toStringAsFixed(2)),
    'height': double.parse(height.toStringAsFixed(2)),
    'lines': lines,
  };
}

/// Serializes measurements for `build/l10n_audit/`.
String encodeMeasurements(List<Measurement> m) =>
    const JsonEncoder.withIndent('  ').convert({
      'count': m.length,
      'measurements': m.map((e) => e.toJson()).toList(),
    });

/// Serializes a run for `build/l10n_audit/` -> the verdict re-deriver reads exactly this and nothing else.
String encodeFindings(List<Finding> findings) =>
    const JsonEncoder.withIndent('  ').convert({
      'count': findings.length,
      'findings': findings.map((f) => f.toJson()).toList(),
    });
