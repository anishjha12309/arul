import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/experiments/experiments.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../domain/regional_art.dart';

part 'launch_art_provider.g.dart';

/// The launch art for this process. The regional arm with `/geo` still unanswered starts AWAITING
/// and the splash [LaunchArtNotifier.settle]s it once, when the answer lands or the cap passes —
/// the art never changes after that, so a late answer can never swap the poster under the wall.
@Riverpod(keepAlive: true)
class LaunchArtNotifier extends _$LaunchArtNotifier {
  @override
  LaunchArt build() {
    if (!ref.read(experimentsProvider).regionalActive) return const LotusArt();
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool(geoPendingPrefsKey) ?? false) {
      return const AwaitingRegionArt();
    }
    return PosterArt(regionalPosterFor(prefs.getString(geoRegionPrefsKey)));
  }

  /// Reads the region as stored right now; a no-op once settled.
  void settle() {
    if (state is! AwaitingRegionArt) return;
    final prefs = ref.read(sharedPreferencesProvider);
    state = PosterArt(regionalPosterFor(prefs.getString(geoRegionPrefsKey)));
  }
}
