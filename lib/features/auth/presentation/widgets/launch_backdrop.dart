import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/motion.dart';
import '../../../../theme/arul_tokens.dart';
import '../../domain/regional_art.dart';
import '../../providers/launch_art_provider.dart';
import '../../providers/launch_clip_provider.dart';
import 'video_background.dart';

/// The poster and its clip share this box, so the texture lands exactly on the poster's pixels.
@visibleForTesting
const Key kLaunchArtFrameKey = Key('launch.art.frame');

/// The splash's and the wall's backdrop: the lotus video, or the regional arm's poster, which its
/// own live clip replaces once that is on disk (launch-surface.md).
class LaunchBackdrop extends ConsumerWidget {
  const LaunchBackdrop({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(launchArtProvider)) {
      LotusArt() => const VideoBackground(overlayOpacity: 0),
      AwaitingRegionArt() => const ColoredBox(color: ArulTokens.darkSurface),
      PosterArt(:final poster) => _PosterBackdrop(poster),
    };
  }
}

class _PosterBackdrop extends ConsumerStatefulWidget {
  const _PosterBackdrop(this.poster);

  final RegionalPoster poster;

  @override
  ConsumerState<_PosterBackdrop> createState() => _PosterBackdropState();
}

class _PosterBackdropState extends ConsumerState<_PosterBackdrop> {
  @override
  void initState() {
    super.initState();
    // After the first frame: the clip's bytes must never race the wall's own paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(launchClipProvider.notifier).wallUp(widget.poster);
    });
  }

  @override
  Widget build(BuildContext context) {
    final poster = widget.poster;
    final clip = ref.watch(launchClipProvider);
    final still = context.reduceMotion;
    return ColoredBox(
      color: ArulTokens.darkSurface,
      child: ClipRect(
        child: Transform.scale(
          scale: poster.zoom,
          alignment: poster.pivot,
          child: FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment(poster.pivot.x, 0),
            child: SizedBox.fromSize(
              key: kLaunchArtFrameKey,
              size: RegionalPoster.frame,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _image(poster, still),
                  if (clip != null) LaunchClipLayer(source: clip),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _image(RegionalPoster poster, bool still) => Image.asset(
    poster.asset,
    fit: BoxFit.fill,
    gaplessPlayback: true,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
    // A decode that finished before this frame shows at once; one that lands later fades in
    // from the dark ground rather than popping.
    frameBuilder: (context, child, frame, sync) {
      if (sync || still) return child;
      return AnimatedOpacity(
        opacity: frame == null ? 0 : 1,
        duration: Motion.imageFade,
        curve: Motion.settleCurve,
        child: child,
      );
    },
  );
}
