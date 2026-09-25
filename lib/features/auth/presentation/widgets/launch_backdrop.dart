import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/motion.dart';
import '../../../../theme/arul_tokens.dart';
import '../../domain/regional_art.dart';
import '../../providers/launch_art_provider.dart';
import 'video_background.dart';

/// The splash's and the wall's backdrop: the lotus video, or the regional arm's still poster.
///
/// The regional arm never creates a player on any tier — bundling a clip per region costs MBs and
/// streaming one fights the sign-in (launch-surface.md).
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

class _PosterBackdrop extends StatelessWidget {
  const _PosterBackdrop(this.poster);

  final RegionalPoster poster;

  @override
  Widget build(BuildContext context) {
    final still = context.reduceMotion;
    return ColoredBox(
      color: ArulTokens.darkSurface,
      child: ClipRect(
        child: Transform.scale(
          scale: poster.zoom,
          alignment: poster.pivot,
          child: _image(still),
        ),
      ),
    );
  }

  Widget _image(bool still) => Image.asset(
        poster.asset,
        fit: BoxFit.cover,
        alignment: Alignment(poster.pivot.x, 0),
        width: double.infinity,
        height: double.infinity,
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
