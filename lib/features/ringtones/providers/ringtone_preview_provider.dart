import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/ringtone.dart';

// Sentinel for copyWith nullable fields.
const Object _absent = Object();

// ─── State ────────────────────────────────────────────────────────────────────

class RingtonePreviewState {
  const RingtonePreviewState({
    this.currentId,
    this.isPlaying = false,
    this.isBuffering = false,
    this.hasError = false,
  });

  /// ID of the ringtone currently loaded (playing or paused). Null = idle.
  final String? currentId;
  final bool isPlaying;

  /// True only while the audio engine is actively loading/buffering — NOT when
  /// paused.
  final bool isBuffering;

  /// True for one state tick after playback fails; cleared by [clearError].
  final bool hasError;

  bool isPlayingId(String id) => currentId == id && isPlaying;

  /// True only during network load/buffer — paused tracks return false.
  bool isLoadingId(String id) => currentId == id && isBuffering;

  RingtonePreviewState copyWith({
    Object? currentId = _absent,
    bool? isPlaying,
    bool? isBuffering,
    bool? hasError,
  }) => RingtonePreviewState(
    currentId: identical(currentId, _absent)
        ? this.currentId
        : currentId as String?,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    hasError: hasError ?? this.hasError,
  );
}

// ─── Notifier ─────────────────────────────────────────────────────────────────

/// One SHARED [AudioPlayer] for all preview playback (ported from the
/// reference): starting a new track stops the old one, so two previews can
/// never play at once, and only one decoder is ever held — this screen shares
/// the device with the feed's video pool.
class RingtonePreviewNotifier extends Notifier<RingtonePreviewState> {
  late final AudioPlayer _player;

  // ── Preview audio disk cache ───────────────────────────────────────────────
  // Nothing cached ringtone bytes: every tap re-streamed the clip from the CDN,
  // so replaying a track heard seconds earlier paid the whole network round
  // trip again — and a preview was impossible offline. This is the same shape
  // as the live-wallpaper disk cache in
  // `wallpapers/data/wallpaper_prefetch_service.dart` (same package, same
  // stalePeriod, same LRU-by-object-count bound, same static-so-it-survives-a-
  // remount lifetime) and the same fix Pakiza already carries for its own
  // ringtone previews.
  //
  // Static for the same reason the wallpaper one is: flutter_cache_manager keys
  // its store by the Config `key`, so a rebuilt notifier (tab remount, re-login)
  // reads the same files — the singleton just avoids redundant managers.
  static final CacheManager _audioCache = CacheManager(
    Config(
      'arulRingtonePreviews',
      // Published audio never changes at a given key (keys are content UUIDs),
      // so this only bounds how long an UNPLAYED clip lingers.
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: _maxCacheObjects,
    ),
  );

  /// LRU bound on object COUNT — flutter_cache_manager has no byte cap.
  ///
  /// The whole catalog is 30 clips of ~0.7 MB, so this holds it several times
  /// over and never evicts during normal use, which is the end Pakiza reaches
  /// via a free-storage ladder; at this size that ladder would be machinery for
  /// nothing. Worst case here is ~84 MB, comfortably below what the live-
  /// wallpaper cache already budgets for 120 multi-MB clips. Revisit if the
  /// catalog ever grows past a few hundred tracks.
  static const _maxCacheObjects = 120;

  @override
  RingtonePreviewState build() {
    _player = AudioPlayer();

    // Mirror player state changes into Riverpod state.
    _player.playerStateStream.listen((ps) {
      if (ps.processingState == ProcessingState.completed) {
        // Track finished — return to idle so the card resets to ▶.
        state = const RingtonePreviewState();
        return;
      }
      final buffering =
          ps.processingState == ProcessingState.loading ||
          ps.processingState == ProcessingState.buffering;
      state = state.copyWith(isPlaying: ps.playing, isBuffering: buffering);
    });

    ref.onDispose(_player.dispose);
    return const RingtonePreviewState();
  }

  /// Toggle play / pause for [ringtone]. If a different track is active, stop
  /// it first and start this one. An empty audio key sets [hasError] so the
  /// screen can toast "Preview not available yet".
  Future<void> toggle(Ringtone ringtone) async {
    // Same track — toggle play / pause.
    if (state.currentId == ringtone.id) {
      if (state.isPlaying) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    // New track — stop whatever is playing and load.
    await _player.stop();
    state = RingtonePreviewState(currentId: ringtone.id, isBuffering: true);

    if (ringtone.audioKey.isEmpty) {
      state = const RingtonePreviewState(hasError: true);
      return;
    }

    ref
        .read(analyticsServiceProvider)
        .track(
          'ringtone_preview',
          properties: {
            'ringtone_id': ringtone.id,
            'category': ringtone.category,
          },
        );

    try {
      final url = ringtone.audioUrl(AppConfig.cdnBaseUrl);

      // Serve from disk when the clip is already there: a track previewed
      // earlier starts instantly and plays offline. getSingleFile returns the
      // cached file on a hit and downloads once on a miss, so the FIRST play
      // fills the cache as a side effect of playing.
      //
      // On ANY cache-backend failure — path_provider unavailable under
      // `flutter test`, a full disk, a corrupt store — fall back to streaming
      // the CDN URL. Preview must never break because caching did.
      String? localPath;
      try {
        localPath = (await _audioCache.getSingleFile(url)).path;
      } catch (e) {
        debugPrint('[RingtonePreview] audio cache unavailable, streaming: $e');
      }

      // A cache MISS awaits a full download, which is a much wider window than
      // the old bare setUrl — long enough for the user to tap another row. That
      // tap has already moved `currentId`, so completing here would start the
      // wrong track against the new row's highlight. Drop the stale load.
      if (state.currentId != ringtone.id) return;

      // Names the source, so "did the cache actually engage on this device?" is
      // answerable from logcat instead of by timing a tap.
      debugPrint(
        '[RingtonePreview] ${localPath != null ? 'disk' : 'net'} $url',
      );
      if (localPath != null) {
        await _player.setFilePath(localPath);
      } else {
        await _player.setUrl(url);
      }
      if (state.currentId != ringtone.id) return;
      await _player.play();
    } catch (e, st) {
      debugPrint('[RingtonePreview] error: $e\n$st');
      // Same reasoning as the guards above: a failure belonging to a track the
      // user has already tapped away from must not toast over the new one.
      if (state.currentId != ringtone.id) return;
      state = const RingtonePreviewState(hasError: true);
    }
  }

  /// Stop playback and reset to idle (called on tab/route change away from the
  /// Ringtones surface — the IndexedStack keeps the screen alive, so audio must
  /// be stopped explicitly, never left playing behind a hidden tab).
  Future<void> stop() async {
    await _player.stop();
    state = const RingtonePreviewState();
  }

  /// Call after consuming the [hasError] flag to prevent duplicate toasts.
  void clearError() {
    if (state.hasError) {
      state = state.copyWith(hasError: false);
    }
  }
}

// ─── Provider ─────────────────────────────────────────────────────────────────

final ringtonePreviewProvider =
    NotifierProvider<RingtonePreviewNotifier, RingtonePreviewState>(
      RingtonePreviewNotifier.new,
    );
