import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/update/update_holds.dart';
import '../../review/presentation/review_prompt_trigger.dart';
import '../domain/cancel_offer.dart';
import '../domain/winback_reach.dart';
import '../providers/winback_reach_providers.dart';

/// A beat shorter than [reviewSettleDelay]: on a launch where both qualify, the ₹99 sheet is
/// that launch's one unrequested surface and the review keeps its arm for a later cold open.
const winbackOpenSettleDelay = Duration(milliseconds: 1500);

/// The app-open ₹99 sheet's one trigger point: the home surface, once its content is on screen.
mixin WinbackOpenTrigger<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Timer? _openTimer;
  bool _openScheduled = false;
  VoidCallback? _openAwaitUpdate;

  /// The host's own "nothing is in flight" — its route, connectivity, running applies or sets.
  bool winbackOpenHostReady();

  /// Call once the host's content is on screen. Only the first call per mount schedules anything.
  void maybeScheduleWinbackOpen() {
    if (_openScheduled) return;
    _openScheduled = true;
    _openTimer = Timer(winbackOpenSettleDelay, _showOnceUpdateDecided);
  }

  // An update outranks the sheet: decide only after this launch's update check has settled.
  void _showOnceUpdateDecided() {
    if (!mounted) return;
    if (UpdateHolds.launch.value == UpdateLaunch.undecided) {
      void listener() {
        if (UpdateHolds.launch.value == UpdateLaunch.undecided) return;
        UpdateHolds.launch.removeListener(listener);
        _openAwaitUpdate = null;
        _showOnceUpdateDecided();
      }

      _openAwaitUpdate = listener;
      UpdateHolds.launch.addListener(listener);
      return;
    }
    unawaited(
      ref
          .read(winbackOpenControllerProvider)
          .maybeShow(surfaceClear: _openSurfaceClear, open: _openSheet),
    );
  }

  bool _openSurfaceClear() {
    if (!mounted) return false;
    // A dialog the OS put over us pauses the Activity -> only `resumed` means they see our screen.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return false;
    }
    if (ArulDeepLink.landedThisLaunch) return false;
    if (UpdateHolds.launch.value != UpdateLaunch.clear) return false;
    if (!reviewSurfaceIsTopmost(context)) return false;
    return winbackOpenHostReady();
  }

  void _openSheet() {
    if (!mounted) return;
    unawaited(
      context.push(
        Uri(
          path: '/premium',
          queryParameters: {
            'source': WinbackEntry.appOpenSource,
            'offer': kWinbackOffer,
          },
        ).toString(),
      ),
    );
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    final awaiting = _openAwaitUpdate;
    if (awaiting != null) UpdateHolds.launch.removeListener(awaiting);
    super.dispose();
  }
}
