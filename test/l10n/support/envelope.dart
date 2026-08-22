/// The gating envelope, and what a finding is.
///
/// Owner's ruling (OVERNIGHT-L10N.md §2): the pass bar is inclusive of all
/// phones, which means the NARROW ones — 320dp and 360dp — at the OS font sizes
/// people actually run, 1.0 and 1.3. Four gating configurations per locale.
///
/// Every gating configuration carries simulated system chrome. A screen that
/// fits only because the harness handed it the status bar's 24dp and the
/// gesture bar's 24dp back is not a screen that fits.
library;

import 'package:flutter/material.dart';

/// One point in the matrix: a width, a height, a text scale, and whether the
/// keyboard is up.
class L10nConfig {
  const L10nConfig({
    required this.id,
    required this.width,
    required this.height,
    required this.textScale,
    required this.gating,
    this.keyboard = false,
  });

  /// Short label used in failure messages, the audit JSON and the ledger.
  final String id;
  final double width;
  final double height;
  final double textScale;

  /// Gating configurations produce demotions. The wide sweep does not: a string
  /// that fits at 320 and breaks at 411 is a layout defect, and demoting a
  /// translation would not fix it (§3).
  final bool gating;

  /// Text-field surfaces get an extra run with the IME up — the sheet shrinks
  /// to roughly half the screen and the copy above the field has to survive it.
  final bool keyboard;

  /// Status-bar-class top inset and gesture-nav bottom inset. Real chrome, so
  /// the vertical budget is the real one.
  static const double topInset = 24;
  static const double bottomInset = 24;

  /// Keyboard height on a 1080×2400-class phone, in logical pixels.
  static const double keyboardInset = 280;

  EdgeInsets get viewInsets =>
      EdgeInsets.only(bottom: keyboard ? keyboardInset : 0);

  @override
  String toString() => id;
}

/// The four gating configurations. A finding at any one of these is demotable.
const List<L10nConfig> kGatingConfigs = <L10nConfig>[
  L10nConfig(
    id: '320x569@1.0',
    width: 320,
    height: 569,
    textScale: 1.0,
    gating: true,
  ),
  L10nConfig(
    id: '320x569@1.3',
    width: 320,
    height: 569,
    textScale: 1.3,
    gating: true,
  ),
  L10nConfig(
    id: '360x640@1.0',
    width: 360,
    height: 640,
    textScale: 1.0,
    gating: true,
  ),
  L10nConfig(
    id: '360x640@1.3',
    width: 360,
    height: 640,
    textScale: 1.3,
    gating: true,
  ),
];

/// Report-only. Catches fits-narrow-breaks-wide, which is a layout defect by
/// definition and never a reason to demote a translation.
///
/// 411x891 is the OWNER'S PHONE at its own settings (1080x2392 @ 420dpi is
/// 411.4 x 911.2 logical), which is why it is here at all — but at scale 1.0 it
/// is the most forgiving frame in the whole envelope and it reports nothing.
/// The 1.3 row is the one that earns its place: an on-device sweep found the
/// language sheet overflowing at 411dp/1.3, a frame this file previously tested
/// only at 1.0, so the harness had no way to see it. Accessibility text size is
/// not a narrow-phone problem — it breaks the widest phone too.
const List<L10nConfig> kSweepConfigs = <L10nConfig>[
  L10nConfig(
    id: '411x891@1.0-sweep',
    width: 411,
    height: 891,
    textScale: 1.0,
    gating: false,
  ),
  L10nConfig(
    id: '411x891@1.3-sweep',
    width: 411,
    height: 891,
    textScale: 1.3,
    gating: false,
  ),
];

/// The extra pass a text-field surface owes, at both gating widths.
const List<L10nConfig> kKeyboardConfigs = <L10nConfig>[
  L10nConfig(
    id: '320x569@1.0+ime',
    width: 320,
    height: 569,
    textScale: 1.0,
    gating: true,
    keyboard: true,
  ),
  L10nConfig(
    id: '360x640@1.3+ime',
    width: 360,
    height: 640,
    textScale: 1.3,
    gating: true,
    keyboard: true,
  ),
];

/// The six shipping locales. English is the baseline every other locale is
/// judged against, so it is always measured, never demoted.
const List<String> kLocales = <String>['en', 'ta', 'te', 'kn', 'ml', 'hi'];

/// Below this share of spare width a string is flagged as a headroom warning —
/// it fits here, but OEM Latin substitution (Samsung and Xiaomi ship non-Roboto
/// Latin faces) could take the last of it. Report-only, never a demotion.
const double kHeadroomFraction = 0.03;
