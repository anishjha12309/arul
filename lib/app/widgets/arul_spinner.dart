import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';

/// Arul's branded busy ring — replaces the stock Material progress ring everywhere in the app.
///
/// A comet arc (partial ring, gradient tail) turns over a faint full-circle track. The gradient is a
/// `Paint.shader` inside a [CustomPainter] -> one ordinary paint call, never `ShaderMask`, which
/// forces an offscreen `saveLayer()` pass every frame. [Motion] drives the turn and `reduceMotion`
/// (from `motion.dart`) parks it -> the SAME track the spinning state already paints, one alpha step
/// up, stands in for motion: never a sweep frozen mid-turn, which reads as a stuck control.
class ArulSpinner extends StatefulWidget {
  const ArulSpinner({
    super.key,
    this.size = 36,
    this.strokeWidth = 2.4,
    this.color,
  });

  /// Diameter. 36 matches the stock indicator's own unsized default -> a call site that never sized
  /// it keeps the same footprint after the swap.
  final double size;

  /// Ring thickness. 2.4 is this app's own convention across its busy states, thinner than
  /// Material's stock 4.
  final double strokeWidth;

  /// Ring colour. Null falls back to whatever foreground colour is already in scope (icon, then
  /// text, then brand maroon) -> a call site that never set one still reads as PART of the control
  /// it sits in, never a fixed brand colour fighting its surroundings.
  final Color? color;

  @override
  State<ArulSpinner> createState() => _ArulSpinnerState();
}

class _ArulSpinnerState extends State<ArulSpinner>
    with SingleTickerProviderStateMixin {
  // 1.6s linear -> the vocabulary's one continuous-spin rhythm.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.hairlineSweep,
  );
  // TickerMode from the route already parks this controller off-page -> a backgrounded screen
  // requests no frames.

  /// Armed from [didChangeDependencies], not the field initializer: `reduceMotion` needs an
  /// InheritedWidget lookup, and a repeating ticker must never start before that answer exists.
  bool _motionStarted = false;

  /// Rest state skips the ticker entirely and paints the track alone, one alpha step up -> never a
  /// sweep frozen at an arbitrary angle.
  bool _spinning = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionStarted) return;
    _motionStarted = true;
    if (context.reduceMotion) {
      _spinning = false;
      // Touches the LATE field on purpose. `_c` is `late final` and the rest path never reads it
      // otherwise, so `dispose()` would be the first read -> the controller would be CONSTRUCTED
      // during unmount, and its ticker's `dependOnInheritedWidgetOfExactType` would run against a
      // defunct element: an assert in debug, and in release a defunct element left registered in
      // TickerMode's dependents. `skeleton.dart` and `sliding_skeleton.dart` park at a value for
      // the same reason; this one has no value to park at, so it just reads the field.
      _c.value = 0;
    } else {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring =
        widget.color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color ??
        ArulTokens.maroon;
    final painter = _spinning
        ? AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _ArulSpinnerPainter(
                color: ring,
                strokeWidth: widget.strokeWidth,
                turn: _c.value,
              ),
            ),
          )
        : CustomPaint(
            painter: _ArulSpinnerPainter(
              color: ring,
              strokeWidth: widget.strokeWidth,
              turn: null,
            ),
          );
    return RepaintBoundary(
      child: SizedBox.square(dimension: widget.size, child: painter),
    );
  }
}

/// A comet arc over a faint track. `turn == null` paints the resting ring only; otherwise the arc
/// sits at `turn * 2π`, `0` at 12 o'clock -> matches where the stock indicator itself starts.
class _ArulSpinnerPainter extends CustomPainter {
  const _ArulSpinnerPainter({
    required this.color,
    required this.strokeWidth,
    required this.turn,
  });

  final Color color;
  final double strokeWidth;
  final double? turn;

  /// The comet's sweep — 270°, long enough to always read as a ring in motion, short enough that
  /// the gradient tail never meets its own head.
  static const _sweep = math.pi * 1.5;

  static const _twoPi = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      // Resting reads as the whole control -> a visible calm ring. Spinning keeps it as a quiet
      // backdrop so the moving arc carries the eye.
      ..color = color.withValues(alpha: turn == null ? 0.40 : 0.16);
    canvas.drawArc(rect, 0, _twoPi, false, track);

    final turnValue = turn;
    // Rest: the track above is the entire picture.
    if (turnValue == null) return;

    final start = turnValue * _twoPi - math.pi / 2;
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      // A gradient FILL, not a mask -> the sheen the house style asks for, drawn in the same pass.
      ..shader = SweepGradient(
        endAngle: _sweep,
        transform: GradientRotation(start),
        colors: [color.withValues(alpha: 0), color],
      ).createShader(rect);
    canvas.drawArc(rect, start, _sweep, false, sweep);
  }

  @override
  bool shouldRepaint(covariant _ArulSpinnerPainter oldDelegate) =>
      oldDelegate.turn != turn ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
