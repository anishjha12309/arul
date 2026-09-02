import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../theme/tokens.dart';

enum ToastKind { info, success, error }

/// Branded toast, on ScaffoldMessenger so it survives navigation and stacks, default surface stripped.
///
/// Flutter 3.38+ -> a SnackBar WITH an action no longer auto-dismisses, turning a transient toast
/// into a permanent bar -> no action button here; anything needing a decision belongs in a sheet.
/// Every meaningful outcome lands here -> this is the ONE place the outcome haptic fires, keyed off
/// [kind] -> callers must never add their own; `haptic: false` marks a toast that is pure chrome.
void showArulToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  bool haptic = true,
}) {
  final messenger = ScaffoldMessenger.of(context);

  if (haptic) {
    switch (kind) {
      case ToastKind.success:
        ArulHaptics.success();
      case ToastKind.error:
        ArulHaptics.error();
      case ToastKind.info:
        ArulHaptics.warning();
    }
  }

  final (accent, icon) = switch (kind) {
    ToastKind.info => (ArulColors.gold, Icons.info_outline_rounded),
    ToastKind.success => (ArulColors.cta, Icons.check_circle_outline_rounded),
    ToastKind.error => (ArulColors.danger, Icons.error_outline_rounded),
  };

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        margin: const EdgeInsets.all(Gap.lg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        content: DecoratedBox(
          decoration: BoxDecoration(
            color: ArulColors.inkRaised,
            borderRadius: Radii.buttonShape,
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.lg,
              vertical: Gap.md,
            ),
            child: Row(
              children: [
                Icon(icon, color: accent, size: 20),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: ArulColors.ivoryText,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
}
