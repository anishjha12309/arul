import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_tokens.dart';
import '../l10n/app_localizations.dart';

/// The Refer & Earn entry in a browse tab's header band — ONE control, shared by both tabs.
///
/// The tabs cross-fade -> two shapes for one affordance read as two unrelated buttons.
/// So this is the single control and a tab supplies only the destination.
/// **A port of Pakiza's `EarnChip`** — geometry, emoji, type and wiggle are its numbers verbatim.
/// Rebuilding it by eye did not converge -> do not try again.
/// The gold is [ArulTokens.gold], never Pakiza's: theming is the one thing the apps never share (§0).
/// **The "shimmer" is the GRADIENT, not an animation** — a sheen plus a hairline lift, nothing moving.
/// A travelling highlight over a video feed costs what the static gradient does not -> no glint.
/// **The gift is the 🎁 emoji**, from the system font -> full-colour, zero asset, zero font dependency.
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

  /// Pill metrics — all Pakiza's.
  /// The gift glyph carries its own side-bearing -> an even 16/16 looks adrift -> padding is ASYMMETRIC.
  static const double _padLeft = 12;
  static const double _padRight = ArulTokens.contentGap; // 16
  static const double _gap = 8;
  static const double _emojiSize = 17;

  /// **Where the button sits — THE knob. Edit this and nothing else.**
  ///
  /// Logical pixels: `dx` negative moves it LEFT of the screen edge, `dy` positive moves it DOWN.
  ///
  /// The band's height is what the reel's card geometry is solved from -> never pad or grow the box.
  /// A TRANSLATE moves paint only and leaves it [ArulTokens.headerControlSize] tall -> nudge freely.
  /// `dx` is 0 -> the button keeps the true [ArulTokens.screenPadding] gutter.
  /// The button owns the real measurable edge -> the optical correction is on the TITLE instead
  /// (`ArulScreenHeader._titleOpticalInset`).
  static const Offset _nudge = Offset(0, 2.5);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _wiggleDuration,
  );

  /// Pakiza's sequence — a wind-up, three swings, a settle; weighted 1·2·2·2·1 so the ends are quicker.
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
  /// A [Timer], not Pakiza's chained `Future.delayed` -> [dispose] can cancel the pending one.
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
        // The label IS the visible word -> without this it announces "Earn, button" then "Earn" again.
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
              // Light only: the dark fill is already brighter than its surface -> no lift needed there.
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
                      // About the BOTTOM-centre, not the middle -> a parcel rattled, not a badge on a pin.
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
                    // Arul's `bodyMedium` carries `height: 1.45` and a Text merges into it -> a 20px
                    // line box for 14px of type.
                    // Flutter puts ~79% of that slack above the baseline -> the word sat visibly low.
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
