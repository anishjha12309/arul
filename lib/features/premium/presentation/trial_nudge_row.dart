import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/entitlement_provider.dart';
import '../providers/trial_nudge_provider.dart';

/// "Finish setting up your free trial" — one row above the browse chips, for someone whose mandate
/// setup died at the UPI app.
///
/// The intent flow's one toast is the only other mention of that failure, and it is gone by the next
/// screen: 12 in 100 trial-tappers ever try a second time, and second attempts convert at about
/// twice the rate of first ones. So the abandonment is written down and asked about ONCE more.
///
/// Renders NOTHING unless there is an unfinished trial, so the header band it sits in is the same
/// height it always was for everyone else.
class TrialNudgeRow extends ConsumerWidget {
  const TrialNudgeRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(trialNudgeProvider)) return const SizedBox.shrink();

    // A grant can land while the marker still says otherwise — a webhook that arrived after the
    // app gave up, or the catch-up poll settling. Premium is the answer that wins, and it forgets
    // the marker rather than merely hiding the row.
    final premium = ref.watch(entitlementProvider).asData?.value;
    if (premium == true) {
      Future.microtask(ref.read(trialNudgeProvider.notifier).resolve);
      return const SizedBox.shrink();
    }
    // Still loading, or signed out: say nothing rather than guess.
    if (premium == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.screenPadding,
        0,
        ArulTokens.screenPadding,
        ArulTokens.chipsTopGap,
      ),
      child: Semantics(
        button: true,
        identifier: 'arul_trial_nudge',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => ArulHaptics.tap(),
          onTap: () {
            // Cleared on the tap, not on the outcome: they have been asked and answered. If this
            // attempt dies too, the payment flow writes a fresh marker.
            ref.read(trialNudgeProvider.notifier).resolve();
            context.push('/premium?source=trial_nudge');
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
              color: ArulTokens.goldTintFill10,
              borderRadius: BorderRadius.circular(ArulTokens.rowRadius),
              border: Border.all(color: ArulTokens.goldBorder52),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.trialNudgeRow,
                        style: ArulTokens.rowTitleTracked.copyWith(
                          color: isDark
                              ? ArulTokens.ivory
                              : ArulTokens.lightText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.premiumCtaTrial,
                        style: ArulTokens.caption.copyWith(
                          color: isDark ? ArulTokens.gold : ArulTokens.maroon,
                        ),
                      ),
                    ],
                  ),
                ),
                Semantics(
                  button: true,
                  label: l10n.trialNudgeDismiss,
                  identifier: 'arul_trial_nudge_dismiss',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => ArulHaptics.tap(),
                    // Hides the row for this process only — the marker survives, so a later cold
                    // start asks once more. They declined to be asked NOW, not ever.
                    onTap: ref.read(trialNudgeProvider.notifier).dismiss,
                    child: SizedBox.square(
                      dimension: ArulTokens.minHitTarget,
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: isDark
                            ? ArulTokens.darkMuted
                            : ArulTokens.lightSecondary,
                      ),
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
}
