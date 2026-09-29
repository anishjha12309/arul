import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';

/// The splash's gold hairline: Arul's one "working" signal on the launch screens, never a spinner.
class ArulHairlineLoader extends StatefulWidget {
  const ArulHairlineLoader({super.key});

  @override
  State<ArulHairlineLoader> createState() => _ArulHairlineLoaderState();
}

class _ArulHairlineLoaderState extends State<ArulHairlineLoader>
    with SingleTickerProviderStateMixin {
  static const _transparentGold = Color.fromRGBO(212, 160, 23, 0);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ArulTokens.hairlineLoop,
  );

  /// Armed here rather than at construction: `reduceMotion` needs an InheritedWidget lookup, and
  /// the splash is the FIRST screen a low-tier phone builds — the one place a loop must not start
  /// before the tier is known.
  bool _motionStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (context.reduceMotion) {
      // Parked at the centre: the gold bar sits fully visible under the wordmark. The splash's only
      // "working" signal must stay legible when it stops moving.
      _controller.value = 0.5;
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 120×2px gold hairline with a sliding gradient, 1.6s linear loop. No spinner — the spec is firm.
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: ArulTokens.hairlineWidth,
      height: ArulTokens.hairlineHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // CSS `background-size: 200% 100%` sliding one tile per loop -> a double-wide bar moved.
            final dx =
                -ArulTokens.hairlineWidth +
                _controller.value * (ArulTokens.hairlineWidth * 2);
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Container(
                width: ArulTokens.hairlineWidth * 2,
                height: ArulTokens.hairlineHeight,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _transparentGold,
                      ArulTokens.gold,
                      ArulTokens.gold,
                      _transparentGold,
                    ],
                    stops: [0.0, 0.4, 0.6, 1.0],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
