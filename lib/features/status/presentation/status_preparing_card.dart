import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/motion.dart';
import '../../../app/widgets/arul_spinner.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/status_action_provider.dart';

// A status Share or Save's wait: the stage's line and the REAL download progress — never a
// percentage, never a timer (the sister app's counter was partly fake).
class StatusPreparingCard {
  const StatusPreparingCard._();

  // False when Back (or a route pushed above) closed it first -> the caller abandons the hand-off,
  // while the action's own guard holds until [until] settles.
  static Future<bool> show(
    BuildContext context, {
    required Future<Object?> until,
  }) async {
    // Root navigator, like the sheet that follows: the dim covers the header and the dock, so the
    // clip being prepared cannot be swiped or tabbed away from under it.
    final themes = InheritedTheme.capture(
      from: context,
      to: Navigator.of(context, rootNavigator: true).context,
    );
    final reduceMotion = context.reduceMotion;
    final closedItself = await showGeneralDialog<bool>(
      context: context,
      // The share sheet's own scrim -> card to sheet reads as one modal moment, not two.
      barrierColor: ArulTokens.sheetOverlay,
      transitionDuration: reduceMotion ? Duration.zero : ArulTokens.dialogEnter,
      pageBuilder: (_, _, _) => themes.wrap(_PreparingCard(until: until)),
      transitionBuilder: (_, anim, _, child) => FadeTransition(
        opacity: anim.drive(CurveTween(curve: ArulTokens.sheetCurve)),
        child: child,
      ),
    );
    return closedItself ?? false;
  }
}

class _PreparingCard extends ConsumerStatefulWidget {
  const _PreparingCard({required this.until});

  final Future<Object?> until;

  @override
  ConsumerState<_PreparingCard> createState() => _PreparingCardState();
}

class _PreparingCardState extends ConsumerState<_PreparingCard> {
  // The action is already idle while the card fades out -> it keeps the last line and bar it showed.
  (StatusActionStage, double?) _last = (StatusActionStage.fetching, null);

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.until.then<void>((_) => _close(), onError: (Object _) => _close()),
    );
  }

  // Pops THIS route only: anything pushed above it (a link, the paywall) must survive the close.
  void _close() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop(true);
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final busy = ref.watch(
      statusActionProvider.select(
        (s) => switch (s) {
          StatusActionBusy(:final stage, :final progress) => (stage, progress),
          _ => null,
        },
      ),
    );
    if (busy != null) _last = busy;
    final (stage, progress) = _last;
    final line = switch (stage) {
      StatusActionStage.fetching => l10n.statusPrepFetching,
      StatusActionStage.preparing => l10n.statusPrepSharing,
      StatusActionStage.saving => l10n.statusPrepSaving,
    };

    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final textColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    final reduceMotion = context.reduceMotion;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ArulSpinner(size: 22, color: accent),
            const SizedBox(width: 14),
            Expanded(
              child: AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : Motion.quick,
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [...previous, ?current],
                ),
                child: Semantics(
                  key: ValueKey(stage),
                  liveRegion: true,
                  child: Text(
                    line,
                    style: ArulTokens.rowTitle.copyWith(color: textColor),
                  ),
                ),
              ),
            ),
          ],
        ),
        // Only a real transfer draws a bar; a clip already on the phone has nothing to fill.
        if (progress != null) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: ArulTokens.gold,
              backgroundColor: isDark
                  ? ArulTokens.goldTintFill14
                  : ArulTokens.maroonTintFill07,
            ),
          ),
        ],
      ],
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              decoration: BoxDecoration(
                color: isDark
                    ? ArulTokens.darkSheetSurface
                    : ArulTokens.cardBgLight,
                border: Border.all(
                  color: isDark
                      ? ArulTokens.goldBorder35
                      : ArulTokens.maroonBorder18,
                ),
                borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
              ),
              // The bar arrives with the first byte of a real transfer -> the card eases to it. A
              // zero-length AnimatedSize asserts mid-layout, so reduced motion takes the end size.
              child: reduceMotion
                  ? body
                  : AnimatedSize(
                      duration: Motion.quick,
                      alignment: Alignment.topCenter,
                      child: body,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
