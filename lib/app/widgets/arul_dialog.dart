import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../../theme/arul_palette.dart';
import '../../theme/arul_tokens.dart';
import '../theme/motion.dart';
import 'arul_ornaments.dart';
import 'arul_pressable.dart';
import 'arul_surface.dart';

/// Shows [builder] as a dialog on the ROOT navigator, wearing the CALLER's theme: /premium pins
/// light at its route, and without the capture a dark phone drew a dark card over the light page.
Future<T?> showArulDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  Color barrierColor = ArulTokens.dialogOverlay,
  String? barrierLabel,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push<T>(
    ArulDialogRoute<T>(
      builder: (context) => themes.wrap(builder(context)),
      still: context.reduceMotion,
      dismissible: dismissible,
      barrierColor: barrierColor,
      barrierLabel:
          barrierLabel ??
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

/// The dialog route: a fade and a small grow in, and out in half the time, accelerating away.
/// `showGeneralDialog` cannot do the second half — its exit always replays the entrance's length.
class ArulDialogRoute<T> extends PopupRoute<T> {
  ArulDialogRoute({
    required this.builder,
    required this.still,
    required this._dismissible,
    required this._barrierColor,
    required this._barrierLabel,
    super.settings,
  });

  final WidgetBuilder builder;

  /// Reduced motion: the dialog and its scrim appear and leave at rest.
  final bool still;

  final bool _dismissible;
  final Color _barrierColor;
  final String _barrierLabel;

  CurvedAnimation? _curve;

  @override
  bool get barrierDismissible => _dismissible;

  @override
  Color get barrierColor => _barrierColor;

  @override
  String get barrierLabel => _barrierLabel;

  @override
  Duration get transitionDuration => still ? Duration.zero : Motion.dialogIn;

  @override
  Duration get reverseTransitionDuration =>
      still ? Duration.zero : Motion.overlayOut;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: builder(context),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (still) return child;
    final t = _curve ??= CurvedAnimation(
      parent: animation,
      curve: Motion.overlayInCurve,
      reverseCurve: Motion.overlayOutCurve,
    );
    return FadeTransition(
      opacity: t,
      child: ScaleTransition(
        scale: Tween<double>(begin: Motion.dialogScaleFrom, end: 1).animate(t),
        child: child,
      ),
    );
  }

  @override
  void dispose() {
    _curve?.dispose();
    super.dispose();
  }
}

/// The app's dialog: the temple crest, a centred title and message, and the two answers.
/// It only RESOLVES — the caller runs the act on the answer.
class ArulDialogCard extends StatelessWidget {
  const ArulDialogCard({
    super.key,
    required this.title,
    required this.message,
    required this.cancel,
    required this.confirm,
  });

  final String title;
  final String message;
  final ArulDialogButton cancel;
  final ArulDialogButton confirm;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return Center(
      // A long message at a large text size outgrows a short phone -> it scrolls, never clips.
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ArulSpace.s24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ArulTokens.dialogMaxWidth,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ArulSurface(
              borderRadius: BorderRadius.circular(ArulTokens.dialogRadius),
              padding: const EdgeInsets.fromLTRB(
                ArulSpace.s24,
                ArulSpace.s20,
                ArulSpace.s24,
                ArulSpace.s24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ArulCrest(),
                  const SizedBox(height: ArulSpace.s12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: ArulTokens.dialogTitle.copyWith(color: p.text),
                  ),
                  const SizedBox(height: ArulSpace.s8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: ArulTokens.body.copyWith(color: p.textSecondary),
                  ),
                  const SizedBox(height: ArulSpace.s20),
                  ArulDialogActions(cancel: cancel, confirm: confirm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Side by side while both labels fit one line at half width; stacked otherwise, the way out
/// first. A label is never shrunk or cut to keep the row.
class ArulDialogActions extends StatelessWidget {
  const ArulDialogActions({
    super.key,
    required this.cancel,
    required this.confirm,
  });

  final ArulDialogButton cancel;
  final ArulDialogButton confirm;

  static const double _gap = ArulSpace.s12;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final room =
          (constraints.maxWidth - _gap) / 2 - 2 * ArulDialogButton.padH - 2;
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final base = DefaultTextStyle.of(context).style;
      bool fits(ArulDialogButton b) {
        final painter = TextPainter(
          text: TextSpan(text: b.label, style: base.merge(b.labelStyle)),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width <= room;
      }

      if (!fits(cancel) || !fits(confirm)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            cancel,
            const SizedBox(height: _gap),
            confirm,
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: cancel),
            const SizedBox(width: _gap),
            Expanded(child: confirm),
          ],
        ),
      );
    },
  );
}

/// One of a dialog's two answers: [filled] is the act (maroon, lit from the top), the other is the
/// way out (an outline in the theme's ink).
class ArulDialogButton extends StatelessWidget {
  const ArulDialogButton({
    super.key,
    required this.label,
    required this.filled,
    required this.onTap,
    required this.identifier,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;
  final String identifier;

  static const double padH = ArulSpace.s12;

  TextStyle get labelStyle => ArulTokens.button.copyWith(
    fontSize: 14.5,
    fontWeight: filled ? FontWeight.w600 : FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return ArulPressable(
      semanticLabel: label,
      identifier: identifier,
      // The act ends something (a session, an account) -> the heaviest beat; the way out is ordinary.
      haptic: filled ? ArulHapticStyle.heavy : ArulHapticStyle.tap,
      pressedScale: 0.97,
      onTap: onTap,
      builder: (context, pressed) {
        final ink = filled ? ArulTokens.ivory : p.text;
        return Container(
          constraints: const BoxConstraints(
            minHeight: ArulTokens.dialogButtonHeight,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(
            horizontal: padH,
            vertical: ArulSpace.s8,
          ),
          decoration: filled
              ? BoxDecoration(
                  color: pressed ? ArulTokens.maroonHover : null,
                  gradient: pressed ? null : ArulTokens.dialogConfirmFill,
                  borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                )
              : BoxDecoration(
                  // A faint wash of its own ink while held; its alpha-0 at rest, never
                  // `Colors.transparent`, which is transparent BLACK.
                  color: ink.withValues(alpha: pressed ? 0.10 : 0),
                  border: Border.all(color: p.outline),
                  borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
                ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: labelStyle.copyWith(color: ink),
          ),
        );
      },
    );
  }
}
