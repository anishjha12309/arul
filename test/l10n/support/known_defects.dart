/// The English baseline, subtracted.
/// A translation-induced finding fires in some locale but NOT in the English baseline of the identical frame.
/// Only those are demotable -> everything else is a layout defect or a designed truncation.
/// Demoting a translation cannot fix a slot that is too small for English either.
/// So this is a set difference against a RECORDED run, never a hand-written allowlist.
/// A hand-maintained list drifts -> every stale entry converts a real overflow into a "known defect".
/// The signature is `kind|screen|config|key`, and CONFIGURATION is part of it on purpose.
/// English "Continue with Google" truncates at 320dp and fits at 360dp.
/// So a Tamil truncation of the same key at 360dp IS translation-induced and must not be swallowed here.
/// Overflows are matched by MAGNITUDE, not by frame -> an overflow finding carries no key.
/// Its signature would collapse to `overflow|screen|config` -> subtracting on that exempts the whole screen everywhere.
/// A Malayalam string pushing a sheet 240px past the bottom would have matched English's 16px and been swallowed.
/// So the baseline records how far English overflowed each frame -> only an overflow no worse than that is subtracted.
library;

import 'attribution.dart' show kAmbiguousMarker;
import 'english_baseline.g.dart';
import 'finding.dart';

/// Slack on the magnitude comparison, in logical pixels -> it covers the sub-pixel difference between two runs.
/// The two layers measured the same upload-screen overflow as 29px and 28px.
const double kOverflowTolerancePx = 1.5;

/// True when [f] also fires in English on the same screen and configuration -> and, for an overflow, no less severely.
bool isKnownDefect(Finding f) {
  // An ambiguous attribution is NEVER subtracted -> two ARB keys share the rendered string.
  // A baseline entry recorded against one of them says nothing about the other.
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
