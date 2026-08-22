/// The English baseline, subtracted.
///
/// §3 of the audit defines a translation-induced finding as one that fires in
/// some locale but NOT in the English baseline of the identical screen, state
/// and configuration. Only those are demotable. Everything else is a layout
/// defect or a designed truncation: demoting a translation cannot fix a slot
/// that is too small for English either.
///
/// So this is a set difference against a RECORDED run, not a hand-written
/// allowlist — see `tools/l10n/gen_english_baseline.dart`. A hand-maintained
/// list drifts, and every stale entry silently converts a real overflow into a
/// "known defect", which is the exact failure this whole harness exists to
/// prevent.
///
/// The signature is `kind|screen|config|key`. Configuration is part of it on
/// purpose: English "Continue with Google" truncates at 320dp and fits at
/// 360dp, so a Tamil truncation of the same key at 360dp IS translation-induced
/// and must not be swallowed here.
///
/// ## Overflows are matched by MAGNITUDE, not by frame
///
/// An overflow finding carries no key — `A RenderFlex overflowed by 16 pixels
/// on the bottom` names a box, not a string — so its signature would collapse
/// to `overflow|screen|config`. Subtracting on that alone exempts the whole
/// screen at that configuration in EVERY locale at ANY size: a Malayalam string
/// pushing the language sheet 240px past the bottom would have matched
/// English's 16px and been swallowed silently. So the baseline records how far
/// English overflowed each frame and only an overflow no worse than that is
/// subtracted.
library;

import 'attribution.dart' show kAmbiguousMarker;
import 'english_baseline.g.dart';
import 'finding.dart';

/// Slack on the magnitude comparison, in logical pixels. Covers the sub-pixel
/// difference between a harness run and a device run of the same frame — Layer
/// 1 and Layer 2 measured the same upload-screen overflow as 29px and 28px.
const double kOverflowTolerancePx = 1.5;

/// True when [f] also fires in English, on the same screen, at the same
/// configuration — and, for an overflow, no less severely.
bool isKnownDefect(Finding f) {
  // An ambiguous attribution must never be subtracted: two ARB keys share the
  // rendered string, so a baseline entry recorded against one of them says
  // nothing about the other.
  if (f.detail.contains(kAmbiguousMarker)) return false;

  if (f.kind == FindingKind.overflow) {
    final parsed = parseOverflowMessage(f.text);
    if (parsed == null) return false;
    final english =
        kEnglishOverflowPx['${f.screen}|${f.config}|${parsed.side}'];
    if (english == null) return false;
    return parsed.px <= english + kOverflowTolerancePx;
  }

  return kEnglishBaseline.contains(
    [f.kind.name, f.screen, f.config, f.key ?? ''].join('|'),
  );
}

/// `A RenderFlex overflowed by 16 pixels on the bottom.`
({double px, String side})? parseOverflowMessage(String message) {
  final m = RegExp(
    r'overflowed by ([\d.]+) pixels on the (\w+)',
  ).firstMatch(message);
  if (m == null) return null;
  return (px: double.parse(m.group(1)!), side: m.group(2)!);
}
