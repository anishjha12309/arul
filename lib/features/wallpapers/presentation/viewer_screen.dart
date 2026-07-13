import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/scrims.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../data/models/wallpaper.dart';
import '../providers/video_preload_provider.dart';
import '../providers/wallpaper_apply_provider.dart';
import '../providers/wallpaper_share_provider.dart';
import '../data/wallpaper_apply_service.dart';
import 'apply_sheet.dart';
import 'video_preload_controller.dart';
import 'viewer_media.dart';
import 'viewer_page.dart';

/// The immersive vertical pager — one wallpaper per screen, full bleed.
///
/// Reached by tapping a grid tile, and it pages through the SAME filtered list
/// the grid was showing, so the user's category context survives the tap.
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  final List<Wallpaper> items;
  final int initialIndex;

  static Route<void> route({
    required List<Wallpaper> items,
    required int initialIndex,
  }) {
    return MaterialPageRoute(
      builder: (_) => ViewerScreen(items: items, initialIndex: initialIndex),
    );
  }

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  late final PageController _pager;
  late int _index;

  /// Chrome is shown by default and toggles on a tap. There was previously no way
  /// to see a wallpaper without something on top of it — which, for a product
  /// whose entire value is the image, was the wrong default to have no escape from.
  bool _chrome = true;

  VideoPreloadController get _video => ref.read(videoPreloadControllerProvider);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pager = PageController(initialPage: _index);

    // Hand the pool the list it is paging through and tell it where we are, so it
    // opens the current clip and preloads the neighbours before they are swiped
    // to. Deferred to after the first frame: setWallpapers synchronously kicks off
    // native player work, and doing that during build would fight the route's own
    // entry transition for the same frame budget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _video
        ..reclaimDecoders()
        ..setWallpapers(widget.items);
      _video.onPageChanged(_index);
    });
  }

  @override
  void dispose() {
    _pager.dispose();
    // Do NOT dispose the controller — it is app-scoped, and disposing it here
    // would race the Android 12+ Activity recreate that a wallpaper apply can
    // trigger. Just give the decoders back: leaving the viewer means nothing on
    // screen needs one.
    _video.releaseDecoders();
    super.dispose();
  }

  Future<void> _onApply(Wallpaper w) async {
    final l10n = AppLocalizations.of(context);

    // Live wallpapers do NOT get our target sheet. Android's live-wallpaper
    // chooser asks "Home screen / Lock screen / Both" itself, and it is the one
    // that decides — so showing our own copy of that question first meant asking
    // the user the same thing twice and honouring the answer neither time
    // (verified on-device: the OS dialog appears regardless of what we pass).
    // Apply goes straight to the download and then to the chooser.
    final ApplyTarget target;
    if (w.kind == WallpaperKind.live) {
      target = ApplyTarget.both;
    } else {
      final picked = await ApplySheet.show(context);
      if (picked == null || !mounted) return; // dismissed — not a failure
      target = picked;
    }

    await ref
        .read(wallpaperApplyProvider.notifier)
        .apply(
          w,
          target: target,
          feedPageIndex: _index,
          category: w.category,
          // Awaited inside the notifier, immediately before the native call: the
          // wallpaper engine (or the OS chooser's preview) is about to need the
          // hardware decoders our feed is holding. On a budget SoC there are only
          // a handful, and not handing them over is what makes a freshly applied
          // live wallpaper fall back to software decode and stutter.
          releaseVideoDecoders: _video.releaseDecoders,
        );

    if (!mounted) return;
    final state = ref.read(wallpaperApplyProvider);
    switch (state) {
      case WallpaperApplySuccess():
        showArulToast(context, l10n.applied);
      case WallpaperApplyError(:final isNetwork, :final message):
        showArulToast(context, isNetwork ? l10n.offlineBody : message);
      // Idle: the OS live-wallpaper chooser is open over us and owns the outcome.
      // We cannot observe whether the user confirmed, so we say nothing rather
      // than claim a success that may not have happened.
      case _:
        break;
    }
    ref.read(wallpaperApplyProvider.notifier).reset();
    // The decoders were handed to the wallpaper engine; take them back so the
    // viewer the user returns to is playing, not frozen.
    if (mounted) _video.reclaimDecoders();
  }

  Future<void> _onShare(Wallpaper w) async {
    final l10n = AppLocalizations.of(context);
    await ref
        .read(wallpaperShareProvider.notifier)
        .share(w, message: l10n.shareMessage);

    if (!mounted) return;
    final state = ref.read(wallpaperShareProvider);
    if (state is WallpaperShareError) {
      showArulToast(
        context,
        state.isNetwork ? l10n.offlineBody : state.message,
      );
      ref.read(wallpaperShareProvider.notifier).reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final apply = ref.watch(wallpaperApplyProvider);
    final share = ref.watch(wallpaperShareProvider);
    final busy =
        apply is WallpaperApplyLoading || share is WallpaperSharePreparing;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // statusBarColor / systemNavigationBarColor are IGNORED at targetSdk 35+.
      // Only icon brightness still applies — and over full-bleed media the icons
      // must be light regardless of the app's theme.
      value: const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF131011),
        body: Stack(
          children: [
            PageView.builder(
              controller: _pager,
              scrollDirection: Axis.vertical,
              // allowImplicitScrolling stays FALSE (the default). True sets the
              // cache extent to ±1 viewport, so three pages get built AND
              // PAINTED — i.e. three live video textures composited every frame,
              // on a GPU that comfortably fits about two.
              itemCount: widget.items.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _video.onPageChanged(i);
              },
              itemBuilder: (context, i) {
                final w = widget.items[i];
                return _Page(
                  wallpaper: w,
                  index: i,
                  chromeVisible: _chrome,
                  busy: busy,
                  onToggleChrome: () => setState(() => _chrome = !_chrome),
                  onApply: busy ? null : () => _onApply(w),
                  onShare: busy ? null : () => _onShare(w),
                );
              },
            ),

            // Progress lives at the top edge, not in a modal over the wallpaper:
            // the user is choosing a wallpaper, and covering it to tell them it is
            // being downloaded defeats the point.
            if (apply is WallpaperApplyLoading)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _ApplyProgress(state: apply),
              ),
          ],
        ),
      ),
    );
  }
}

/// One page, rebuilt only when its own slot / chrome state changes.
class _Page extends ConsumerWidget {
  const _Page({
    required this.wallpaper,
    required this.index,
    required this.chromeVisible,
    required this.busy,
    required this.onToggleChrome,
    required this.onApply,
    required this.onShare,
  });

  final Wallpaper wallpaper;
  final int index;
  final bool chromeVisible;
  final bool busy;
  final VoidCallback onToggleChrome;
  final VoidCallback? onApply;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching the controller (a ChangeNotifier) rebuilds this page when the pool
    // reassigns players — which is exactly when the slot for this index changes.
    final controller = ref.watch(videoPreloadControllerProvider);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final slot = controller.slotForIndex(index);
        return ViewerPage(
          wallpaper: wallpaper,
          media: ViewerMedia(wallpaper: wallpaper, slot: slot),
          chromeVisible: chromeVisible,
          busy: busy,
          onToggleChrome: onToggleChrome,
          onApply: onApply,
          onShare: onShare,
        );
      },
    );
  }
}

/// A hairline determinate/indeterminate bar under the status bar.
class _ApplyProgress extends StatelessWidget {
  const _ApplyProgress({required this.state});

  final WallpaperApplyLoading state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.viewPaddingOf(context).top),
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: ArulScrims.top),
        child: SizedBox(
          height: Gap.xs,
          child: LinearProgressIndicator(
            // Null while preparing/applying — those stages have no measurable
            // progress, and a bar sitting at 0% reads as "stuck", not as "working".
            value: state.stage == WallpaperApplyStage.downloading
                ? state.progress
                : null,
            minHeight: Gap.xs,
            backgroundColor: Colors.transparent,
          ),
        ),
      ),
    );
  }
}
