import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/arul_tokens.dart';

/// The two premium-gated verbs. Browse and preview are free; Apply and Share are
/// gated (CLAUDE.md §5). Carries its own nudge copy so the feed does not spell it.
enum PremiumGateAction {
  apply('apply', 'Applying is a premium treat — ', 'try it free'),
  share('share', 'Sharing is a premium treat — ', 'try it free');

  const PremiumGateAction(this.source, this.nudgeLead, this.nudgeAccent);

  /// The `?source=` value forwarded to `/premium` and the blocked-action
  /// analytics key.
  final String source;

  /// Plain leading half of the nudge line.
  final String nudgeLead;

  /// Bold-gold trailing half of the nudge line.
  final String nudgeAccent;
}

/// The floating premium nudge pill shown on the FIRST gated tap in a session
/// (README > Premium gate): `bg rgba(20,9,12,.92)`, gold-45% border, r999, pad
/// 9 18, gold `workspace_premium` 17px + a 13px line whose tail is bold gold.
///
/// Rises (translateY + fade) on mount like the sheets, holds for
/// [ArulTokens.nudgeAutoDismiss] (~2.6s), then fades out and calls [onDismissed].
/// The caller positions it (above the meta) and rebuilds it with a fresh [key]
/// per tap so the entrance replays.
class PremiumNudge extends StatefulWidget {
  const PremiumNudge({
    super.key,
    required this.action,
    required this.onDismissed,
    required this.onTap,
  });

  final PremiumGateAction action;
  final VoidCallback onDismissed;

  /// Tapping the pill goes STRAIGHT to the paywall. The pill says "try it free",
  /// so it has to be a door — it was previously wrapped in IgnorePointer and
  /// tapping it did nothing, stranding the user on a dead-end promise.
  final VoidCallback onTap;

  @override
  State<PremiumNudge> createState() => _PremiumNudgeState();
}

class _PremiumNudgeState extends State<PremiumNudge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ArulTokens.sheetEnter, // same rise as the sheets (300ms)
  );

  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: ArulTokens.sheetCurve, // ease
  );

  Timer? _dismiss;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _dismiss = Timer(ArulTokens.nudgeAutoDismiss, () async {
      if (!mounted) return;
      await _c.reverse();
      if (mounted) widget.onDismissed();
    });
  }

  @override
  void dispose() {
    _dismiss?.cancel();
    _c.dispose();
    super.dispose();
  }

  /// The pill is a live target for as long as it is on screen. Cancel the
  /// auto-dismiss first, or the timer fires mid-navigation and calls back into a
  /// feed that has already pushed the paywall.
  void _handleTap() {
    _dismiss?.cancel();
    HapticFeedback.lightImpact();
    widget.onTap();
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${widget.action.nudgeLead}${widget.action.nudgeAccent}',
      child: GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) => Opacity(
            opacity: _t.value,
            child: Transform.translate(
              offset: Offset(0, (1 - _t.value) * 24),
              child: child,
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
              color: ArulTokens.darkSurface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
              border: Border.all(
                color: ArulTokens.gold.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.workspace_premium_rounded,
                  size: 17,
                  color: ArulTokens.gold,
                ),
                const SizedBox(width: 8),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: ArulTokens.ivory,
                    ),
                    children: [
                      TextSpan(text: widget.action.nudgeLead),
                      TextSpan(
                        text: widget.action.nudgeAccent,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: ArulTokens.gold,
                        ),
                      ),
                    ],
                  ),
                ),
                // The pill is now tappable — signal it. Without an affordance a
                // gold word just looks like emphasis.
                const SizedBox(width: 6),
                const Icon(
                  Icons.arrow_forward_rounded,
                  size: 15,
                  color: ArulTokens.gold,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
