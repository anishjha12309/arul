import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';

/// A centred confirm dialog — 24px margins, r22, gold-35% border on `#1A0B0F`.
/// Title 18px/600, message 13.5px secondary, two 46px r999 buttons: outlined Cancel, solid confirm.
///
/// The dialog only RESOLVES the answer — `true` on confirm, `false` or `null` on cancel.
/// The CALLER runs the real action (logout, delete account) on `true`.
/// Entrance is translateY(24)+fade over 250ms, behind [ArulTokens.dialogOverlay].
Future<bool?> showArulConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) {
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: ArulTokens.dialogOverlay, // rgba(20,9,12,.60)
    transitionDuration: ArulTokens.dialogEnter, // 250ms
    pageBuilder: (context, _, _) => _ConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
    transitionBuilder: (context, anim, _, child) {
      final t = CurvedAnimation(parent: anim, curve: ArulTokens.sheetCurve);
      return Opacity(
        opacity: t.value,
        child: Transform.translate(
          offset: Offset(0, (1 - t.value) * 24),
          child: child,
        ),
      );
    },
  );
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // The light variant is spec-unspecified -> it mirrors the dark: white card, maroon-tinted border.
    final cardColor = isDark
        ? ArulTokens.darkSheetSurface
        : ArulTokens.cardBgLight;
    final borderColor = isDark
        ? ArulTokens.goldBorder35
        : ArulTokens.maroonBorder18;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final messageColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    // Cancel outline "ivory 25%" equals [ArulTokens.grabberColorDark] exactly — the only such token.
    final cancelBorder = isDark
        ? ArulTokens.grabberColorDark
        : ArulTokens.maroonBorder18;
    final cancelText = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    return Center(
      child: Padding(
        // 24px side margins.
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
            decoration: BoxDecoration(
              color: cardColor,
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: ArulTokens.sheetTitle.copyWith(
                    fontSize: 18,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: ArulTokens.body.copyWith(color: messageColor),
                ),
                const SizedBox(height: 20), // 8px gap + 12px margin-top
                Row(
                  children: [
                    Expanded(
                      child: _DialogButton(
                        label: AppLocalizations.of(context).cancel,
                        filled: false,
                        borderColor: cancelBorder,
                        textColor: cancelText,
                        onTap: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _DialogButton(
                        label: confirmLabel,
                        filled: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One 46px r999 dialog button — filled is solid maroon; outlined is transparent with a hairline.
class _DialogButton extends StatefulWidget {
  const _DialogButton({
    required this.label,
    required this.filled,
    required this.onTap,
    this.borderColor,
    this.textColor,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;
  final Color? borderColor;
  final Color? textColor;

  @override
  State<_DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<_DialogButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color bg = widget.filled
        ? (_pressed ? ArulTokens.maroonHover : ArulTokens.maroon)
        : Colors.transparent;
    final Color textColor = widget.filled
        ? ArulTokens.ivory
        : (widget.textColor ?? ArulTokens.darkText);

    return GestureDetector(
      // The FILLED button is the destructive one here -> the heaviest beat; Cancel is ordinary.
      onTapDown: (_) {
        ArulHaptics.fire(
          widget.filled ? ArulHapticStyle.heavy : ArulHapticStyle.tap,
        );
        setState(() => _pressed = true);
      },
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Container(
        height: ArulTokens.dialogButtonHeight, // 46
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: widget.filled
              ? null
              : Border.all(
                  color: widget.borderColor ?? ArulTokens.grabberColorDark,
                ),
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        ),
        child: Text(
          widget.label,
          style: ArulTokens.button.copyWith(
            fontSize: 14.5,
            fontWeight: widget.filled ? FontWeight.w600 : FontWeight.w500,
            color: textColor,
          ),
        ),
      ),
    );
  }
}
