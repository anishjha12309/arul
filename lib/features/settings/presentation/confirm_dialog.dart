import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_dialog.dart';

/// The dialog only RESOLVES the answer — `true` on confirm, `false` or `null` on cancel.
/// The CALLER runs the real action (logout, delete account) on `true`.
Future<bool?> showArulConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? cancelLabel,
}) => showArulDialog<bool>(
  context,
  barrierLabel: title,
  builder: (context) => ArulDialogCard(
    title: title,
    message: message,
    cancel: ArulDialogButton(
      // A dialog whose ACTION is a cancel must name its way out differently, or both buttons
      // read "cancel".
      label: cancelLabel ?? AppLocalizations.of(context).cancel,
      filled: false,
      identifier: 'arul_confirm_cancel',
      onTap: () => Navigator.of(context).pop(false),
    ),
    confirm: ArulDialogButton(
      label: confirmLabel,
      filled: true,
      identifier: 'arul_confirm_ok',
      onTap: () => Navigator.of(context).pop(true),
    ),
  ),
);
