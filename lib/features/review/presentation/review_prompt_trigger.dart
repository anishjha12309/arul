import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/deeplink/deep_link_target.dart';
import '../../../core/update/update_holds.dart';
import '../providers/review_prompt_controller.dart';

/// Lets a late post-frame surface (the push permission dialog, a paywall push, an update prompt)
/// claim the screen first, so the guard sees it rather than racing it.
const reviewSettleDelay = Duration(seconds: 2);

/// Whether nothing sits above [context] in ANY navigator up to the root — no pushed route, sheet,
/// dialog or local-history entry.
///
/// `canPop`, never `ModalRoute.of`: the latter subscribes the caller, and the feed would rebuild on
/// every sheet open and close.
bool reviewSurfaceIsTopmost(BuildContext context) {
  var nav = context.findAncestorStateOfType<NavigatorState>();
  while (nav != null) {
    if (nav.canPop()) return false;
    nav = nav.context.findAncestorStateOfType<NavigatorState>();
  }
  return true;
}

/// The one trigger point for Play's review sheet: the home surface, once its content has loaded.
mixin ReviewPromptTrigger<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  Timer? _reviewTimer;
  bool _reviewScheduled = false;
  VoidCallback? _awaitUpdate;

  /// The host's own "nothing is in flight" — its route, connectivity, running applies or sets.
  bool reviewHostReady();

  /// Call once the host's content is on screen. Only the first call per mount schedules anything.
  void maybeScheduleReviewPrompt() {
    if (_reviewScheduled) return;
    _reviewScheduled = true;
    _reviewTimer = Timer(reviewSettleDelay, _askOnceUpdateDecided);
  }

  // The update outranks the review: ask only after this launch's update check has settled.
  void _askOnceUpdateDecided() {
    if (!mounted) return;
    if (UpdateHolds.launch.value == UpdateLaunch.undecided) {
      void listener() {
        if (UpdateHolds.launch.value == UpdateLaunch.undecided) return;
        UpdateHolds.launch.removeListener(listener);
        _awaitUpdate = null;
        _askOnceUpdateDecided();
      }

      _awaitUpdate = listener;
      UpdateHolds.launch.addListener(listener);
      return;
    }
    try {
      unawaited(
        ref.read(reviewPromptControllerProvider).maybeAsk(_reviewSurfaceClear),
      );
    } catch (e) {
      // A container without prefs (a screen test) -> no ask, and nothing thrown from a timer.
      debugPrint('[Review] trigger unavailable: $e');
    }
  }

  bool _reviewSurfaceClear() {
    if (!mounted) return false;
    // Anything the OS put over us (a permission dialog, a chooser, Play's own update flow) pauses
    // the Activity -> only `resumed` means the person is looking at our screen.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return false;
    }
    if (ArulDeepLink.landedThisLaunch) return false;
    if (UpdateHolds.launch.value != UpdateLaunch.clear) return false;
    if (!reviewSurfaceIsTopmost(context)) return false;
    return reviewHostReady();
  }

  @override
  void dispose() {
    _reviewTimer?.cancel();
    final awaiting = _awaitUpdate;
    if (awaiting != null) UpdateHolds.launch.removeListener(awaiting);
    super.dispose();
  }
}
