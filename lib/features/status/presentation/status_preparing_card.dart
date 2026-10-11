import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/motion.dart';
import '../../../app/widgets/arul_dialog.dart';
import '../../../app/widgets/arul_spinner.dart';
import '../../../app/widgets/arul_surface.dart';
import '../../../theme/arul_palette.dart';
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
    final closedItself = await showArulDialog<bool>(
      context,
      dismissible: false,
      // The share sheet's own scrim -> card to sheet reads as one modal moment, not two.
      barrierColor: ArulTokens.sheetOverlay,
      builder: (_) => _PreparingCard(until: until),
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
    final p = ArulPalette.of(context);
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

    final reduceMotion = context.reduceMotion;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ArulSpinner(size: 22, color: p.accent),
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
                    style: ArulTokens.rowTitle.copyWith(color: p.text),
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
              backgroundColor: p.accentTint,
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
            child: ArulSurface(
              borderRadius: BorderRadius.circular(ArulTokens.dialogRadius),
              padding: const EdgeInsets.all(ArulSpace.s20),
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
