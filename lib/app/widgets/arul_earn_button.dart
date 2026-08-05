import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';
import '../l10n/app_localizations.dart';

/// The Refer & Earn entry in a browse tab's header band — ONE control, shared
/// by Wallpapers and Ringtones.
///
/// It used to be two things: a bare shaking gift glyph on the feed and a
/// labelled outline pill on Ringtones. The tabs cross-fade into one another, so
/// the same affordance changing shape, size and motion between them read as two
/// unrelated buttons. This is the single one; a tab supplies only the
/// destination.
///
/// **This is a port of Pakiza's `EarnChip`** (`lib/core/widgets/earn_chip.dart`,
/// 2026-08-06), and deliberately so — it is the design the reference art came
/// from, and rebuilding it by eye did not converge. Its geometry, its emoji, its
/// type and its wiggle are Pakiza's numbers verbatim. What did NOT come across
/// is the palette: the gold is [ArulTokens.gold], not Pakiza's, because a theme
/// is the one thing the two apps deliberately never share (CLAUDE.md §0).
///
/// Two consequences worth knowing before touching this:
///
///   * **The "shimmer" is the gradient, not an animation.** A soft white→cream
///     vertical sheen ([ArulTokens.earnFillLight]) plus a hairline lift is the
///     whole effect. An animated glint lived here briefly and is gone — Pakiza
///     has none, and a travelling highlight over a video feed is a cost the
///     static gradient does not pay.
///   * **The gift is the 🎁 emoji**, rendered by the system emoji font. That is
///     why it is full-colour and dimensional where a painted two-tone glyph was
///     not, and it stays a zero-asset, zero-font-dependency control — the same
///     reason docs/ui-direction.md §Perf bans icon fonts in the first place.
class ArulEarnButton extends StatefulWidget {
  const ArulEarnButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<ArulEarnButton> createState() => _ArulEarnButtonState();
}

class _ArulEarnButtonState extends State<ArulEarnButton>
    with SingleTickerProviderStateMixin {
  /// One wiggle, and the pause between them. Pakiza's 550ms / 3s.
  static const Duration _wiggleDuration = Duration(milliseconds: 550);
  static const Duration _wiggleGap = Duration(seconds: 3);

  /// Pill metrics — all Pakiza's. The padding is ASYMMETRIC on purpose: the
  /// gift glyph carries its own optical side-bearing, so an even 16/16 leaves
  /// it looking adrift from the left rim.
  static const double _padLeft = 12;
  static const double _padRight = ArulTokens.contentGap; // 16
  static const double _gap = 8;
  static const double _emojiSize = 17;

  /// **Where the button sits — THE knob. Edit this and nothing else.**
  ///
  /// Logical pixels: `dx` negative moves it LEFT (away from the screen edge),
  /// positive right; `dy` positive moves it DOWN.
  ///
  /// It is a TRANSLATE, deliberately. Padding or a taller box would change the
  /// layout, and the band's height is what the reel's card geometry is solved
  /// from — this moves only the paint and leaves the box exactly
  /// [ArulTokens.headerControlSize] tall, so no value here can push the feed
  /// around. Nudge it freely.
  /// `dx` is 0: the button keeps the true [ArulTokens.screenPadding] gutter.
  /// The optical correction that used to live here is on the TITLE instead
  /// (`ArulScreenHeader._titleOpticalInset`) — the button is the element with a
  /// real, measurable edge, so it is the one that should hold the gutter
  /// honestly and the text that should be nudged to look level against it.
  static const Offset _nudge = Offset(0, 2.5);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _wiggleDuration,
  );

  /// Pakiza's sequence: a small wind-up, three full swings, a settle. Weighted
  /// 1·2·2·2·1 so the ends are quicker than the middle.
  late final Animation<double> _wiggle = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: -0.22), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -0.22, end: 0.22), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 0.22, end: -0.22), weight: 2),
    TweenSequenceItem(tween: Tween(begin: -0.22, end: 0.22), weight: 2),
    TweenSequenceItem(tween: Tween(begin: 0.22, end: 0.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// Re-arms the attention wiggle for as long as this is mounted.
  ///
  /// A [Timer] rather than Pakiza's chained `Future.delayed`, so [dispose] can
  /// actually cancel the pending one instead of letting it fire into a
  /// `mounted` check.
  void _schedule() {
    _timer = Timer(_wiggleGap, () {
      if (!mounted) return;
      _c.forward(from: 0).whenComplete(() {
        if (mounted) _schedule();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Transform.translate(
      offset: _nudge,
      child: Semantics(
        container: true,
        button: true,
        label: l10n.earn,
        // The label IS the visible word, so without this the button announces
        // "Earn, button" and then "Earn" again for the Text inside it.
        excludeSemantics: true,
        child: GestureDetector(
          onTapDown: (_) => ArulHaptics.tap(),
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: ArulTokens.headerControlSize,
            padding: const EdgeInsets.only(left: _padLeft, right: _padRight),
            decoration: BoxDecoration(
              gradient: isDark
                  ? ArulTokens.earnFillDark
                  : ArulTokens.earnFillLight,
              borderRadius: BorderRadius.circular(
                ArulTokens.headerButtonRadius,
              ),
              border: Border.all(
                color: isDark
                    ? ArulTokens.earnBorderDark
                    : ArulTokens.earnBorderLight,
              ),
              // Light only — see the token. Dark needs no lift; the fill is
              // already brighter than the surface it sits on.
              boxShadow: isDark ? null : ArulTokens.controlLift,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _wiggle,
                    builder: (context, child) => Transform.rotate(
                      angle: _wiggle.value,
                      // About the BOTTOM-centre of the box, not the middle, so
                      // it reads as a parcel being rattled rather than a badge
                      // spinning on a pin.
                      origin: const Offset(0, 6),
                      child: child,
                    ),
                    child: const Text(
                      '🎁',
                      style: TextStyle(fontSize: _emojiSize),
                    ),
                  ),
                ),
                const SizedBox(width: _gap),
                Text(
                  l10n.earn,
                  style: TextStyle(
                    color: isDark ? ArulTokens.gold : ArulTokens.goldInkLight,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: 0.2,
                    // Arul-side necessity, not Pakiza's: this app's `bodyMedium`
                    // carries `height: 1.45`, and a Text merges into it. Left
                    // alone the label gets a 20px line box for 14px of type and
                    // Flutter hands the slack out ~79% above the baseline, so
                    // the word sits visibly low in the button.
                    height: 1,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
