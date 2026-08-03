import 'package:flutter/material.dart';

import '../../core/haptics/arul_haptics.dart';
import '../theme/tokens.dart';

enum ToastKind { info, success, error }

/// Branded toast. Built on ScaffoldMessenger (so it survives navigation and
/// stacks correctly) but with the default surface stripped out.
///
/// No action button by design: since Flutter 3.38 a SnackBar WITH an action no
/// longer auto-dismisses, which turns a transient toast into a permanent bar.
/// Anything needing a decision belongs in a sheet, not a toast.
///
/// Every meaningful outcome in the app lands here — wallpaper applied, share
/// failed, name updated — so this is also the ONE place the outcome haptic
/// fires, keyed off [kind]. Callers must not add their own; that would double up
/// on the same beat. Pass `haptic: false` for a toast that is pure chrome.
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
