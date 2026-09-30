import 'package:flutter/material.dart';

import '../../../app/theme/motion.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import 'paywall_ornaments.dart';

/// `showArulConfirmDialog` in /premium's own dress; `true` on confirm, `false` or `null` otherwise.
Future<bool?> showPremiumConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String cancelLabel,
}) => showGeneralDialog<bool>(
  context: context,
  barrierDismissible: true,
  barrierLabel: title,
  barrierColor: ArulTokens.dialogOverlay,
  transitionDuration: ArulTokens.dialogEnter,
  pageBuilder: (_, _, _) => _PremiumConfirmDialog(
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
  ),
  transitionBuilder: (context, animation, _, child) {
    if (context.reduceMotion) return child;
    final t = CurvedAnimation(parent: animation, curve: ArulTokens.sheetCurve);
    return FadeTransition(
      opacity: t,
      child: AnimatedBuilder(
        animation: t,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, (1 - t.value) * 24),
          child: child,
        ),
        child: child,
      ),
    );
  },
);

class _PremiumConfirmDialog extends StatelessWidget {
  const _PremiumConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    // Clamped as PaywallGround clamps the page behind it.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Material(
            type: MaterialType.transparency,
            // The member view's card: cream gradient, soft gold rim, the same radius.
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: ArulTokens.paywallPanelFill,
                border: Border.all(color: ArulTokens.paywallBorderSoft),
                borderRadius: BorderRadius.circular(
                  ArulTokens.premiumMemberCardRadius,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        PaywallOrnamentWing(
                          ruleWidth: 26,
                          floretSize: ArulTokens.premiumMemberHeroFloretSize,
                          gap: ArulTokens.premiumMemberHeroOrnamentGap,
                        ),
                        SizedBox(
                          width: ArulTokens.premiumMemberHeroOrnamentGap,
                        ),
                        PaywallOrnamentImage(
                          ornament: PaywallOrnament.gopuram,
                          width: 34,
                        ),
                        SizedBox(
                          width: ArulTokens.premiumMemberHeroOrnamentGap,
                        ),
                        PaywallOrnamentWing(
                          ruleWidth: 26,
                          floretSize: ArulTokens.premiumMemberHeroFloretSize,
                          gap: ArulTokens.premiumMemberHeroOrnamentGap,
                          mirrored: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: ArulTokens.premiumMemberHeadline.copyWith(
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: ArulTokens.premiumMemberSublineGap),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: ArulTokens.premiumMemberBody.copyWith(
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _ButtonPair(
                      keep: _PremiumDialogButton(
                        label: cancelLabel,
                        filled: false,
                        identifier: 'arul_confirm_cancel',
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                      confirm: _PremiumDialogButton(
                        label: confirmLabel,
                        filled: true,
                        identifier: 'arul_confirm_ok',
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                      keepLabel: cancelLabel,
                      confirmLabel: confirmLabel,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Side by side while both labels fit one line at half width; stacked otherwise. Half-width at
// 320 dp / 1.3 broke "premium" mid-word, and shrinking the label is what the pills refuse to do.
class _ButtonPair extends StatelessWidget {
  const _ButtonPair({
    required this.keep,
    required this.confirm,
    required this.keepLabel,
    required this.confirmLabel,
  });

  final Widget keep;
  final Widget confirm;
  final String keepLabel;
  final String confirmLabel;

  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final room =
          (constraints.maxWidth - _gap) / 2 -
          2 * _PremiumDialogButton.hPadding -
          2 * ArulTokens.premiumMemberControlStroke;
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      bool fitsOneLine(String label, TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width <= room;
      }

      final fits =
          fitsOneLine(keepLabel, _PremiumDialogButton.outlineStyle) &&
          fitsOneLine(confirmLabel, _PremiumDialogButton.filledStyle);
      if (!fits) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            keep,
            const SizedBox(height: _gap),
            confirm,
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: keep),
            const SizedBox(width: _gap),
            Expanded(child: confirm),
          ],
        ),
      );
    },
  );
}

// Filled = the paywall's maroon CTA fill; outline = the member view's quiet cancel pill.
class _PremiumDialogButton extends StatefulWidget {
  const _PremiumDialogButton({
    required this.label,
    required this.filled,
    required this.identifier,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final String identifier;
  final VoidCallback onTap;

  static const hPadding = 12.0;
  static final filledStyle = ArulTokens.paywallCtaLabel.copyWith(fontSize: 15);
  static const outlineStyle = ArulTokens.premiumMemberCancelLabel;

  @override
  State<_PremiumDialogButton> createState() => _PremiumDialogButtonState();
}

class _PremiumDialogButtonState extends State<_PremiumDialogButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final decoration = widget.filled
        ? BoxDecoration(
            gradient: ArulTokens.paywallCtaFill,
            border: Border.all(color: ArulTokens.paywallGold500),
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          )
        : BoxDecoration(
            color: ArulTokens.paywallMaroon.withValues(
              alpha: _pressed
                  ? ArulTokens.premiumMemberCancelPressedAlpha
                  : ArulTokens.premiumMemberCancelFillAlpha,
            ),
            border: Border.all(
              color: ArulTokens.paywallMaroon.withValues(
                alpha: ArulTokens.premiumMemberCancelBorderAlpha,
              ),
              width: ArulTokens.premiumMemberControlStroke,
            ),
            borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          );

    return Semantics(
      button: true,
      label: widget.label,
      identifier: widget.identifier,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The filled button ends the plan -> the heaviest beat; keeping it is ordinary.
        onTapDown: (_) {
          ArulHaptics.fire(
            widget.filled ? ArulHapticStyle.heavy : ArulHapticStyle.tap,
          );
          setState(() => _pressed = true);
        },
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed && !context.reduceMotion
              ? ArulTokens.paywallPressScale
              : 1,
          duration: context.reduceMotion
              ? Duration.zero
              : ArulTokens.paywallPress,
          curve: ArulTokens.settleCurve,
          child: Container(
            constraints: const BoxConstraints(
              minHeight: ArulTokens.dialogButtonHeight,
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(
              horizontal: _PremiumDialogButton.hPadding,
              vertical: 8,
            ),
            decoration: decoration,
            child: Text(
              widget.label,
              textAlign: TextAlign.center,
              style: widget.filled
                  ? _PremiumDialogButton.filledStyle
                  : _PremiumDialogButton.outlineStyle,
            ),
          ),
        ),
      ),
    );
  }
}
