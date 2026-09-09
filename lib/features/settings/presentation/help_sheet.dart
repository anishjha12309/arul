import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/subscription_model.dart';
import '../../../theme/arul_tokens.dart';
import '../../premium/providers/entitlement_provider.dart';

/// What the reader picked in the help sheet.
enum HelpAction { support, manage, delete }

/// The Need help? sheet — contact support, manage the plan, delete the account.
///
/// Like the language and theme sheets it only RESOLVES a choice and acts on nothing: the mailto,
/// the confirm dialog and the `/premium` push all run from Settings, after the sheet is gone.
/// A dialog raised from a sheet that is closing loses its context; a mailto does not.
Future<HelpAction?> showHelpSheet(BuildContext context) {
  return showArulSheet<HelpAction>(
    context,
    // The gold edge reads as a stray line on a sheet this small -> off, as on the theme sheet.
    topHairline: false,
    builder: (_) => const _HelpSheet(),
  );
}

class _HelpSheet extends ConsumerWidget {
  const _HelpSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    // WATCHED, not read: a cold open resolves the entitlement while the sheet is already up, and
    // the row must appear when it lands rather than on the next visit.
    final entitlement = ref.watch(entitlementDetailProvider).asData?.value;
    // Non-null is BOTH the row's visibility and its sub -> the two can never disagree.
    // These are exactly the states where `/premium` renders a manage view (member or resubscribe);
    // every other one is a sell, and a row named "Manage subscription" may never lead to one.
    // Not a second entitlement rule: the flag stays the server's and this reads the same `status`
    // field `/premium` itself switches on.
    final manageSub = entitlement?.isPremium != true
        ? null
        : switch (entitlement?.subscription?.status) {
            SubscriptionStatus.trialing => l10n.settingsPremiumSubTrial,
            SubscriptionStatus.active => l10n.settingsPremiumSubActive,
            SubscriptionStatus.cancelled => l10n.settingsPremiumSubCancelled,
            _ => null,
          };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.settingsNeedHelp,
            style: ArulTokens.sheetTitle.copyWith(color: titleColor),
          ),
          const SizedBox(height: 14),
          ArulSheetRow(
            icon: Icons.mail_outline_rounded,
            title: l10n.settingsHelpSupport,
            sub: l10n.settingsHelpSupportSub,
            identifier: 'arul_settings_help_support',
            onTap: () => Navigator.of(context).pop(HelpAction.support),
          ),
          if (manageSub != null) ...[
            const SizedBox(height: kSheetRowGap),
            ArulSheetRow(
              // The brand mark, as on every other premium surface — never a laurel badge.
              glyph: (color) => GopuramMark(size: 19, color: color),
              title: l10n.settingsHelpManage,
              sub: manageSub,
              identifier: 'arul_settings_help_manage',
              onTap: () => Navigator.of(context).pop(HelpAction.manage),
            ),
          ],
          const SizedBox(height: kSheetRowGap),
          ArulSheetRow(
            icon: Icons.delete_outline_rounded,
            title: l10n.settingsDeleteAccount,
            sub: l10n.settingsHelpDeleteSub,
            identifier: 'arul_settings_delete',
            destructive: true,
            // The strongest beat in the app, twice — as on the link this row replaced.
            haptic: ArulHapticStyle.heavy,
            onTap: () => Navigator.of(context).pop(HelpAction.delete),
          ),
        ],
      ),
    );
  }
}
