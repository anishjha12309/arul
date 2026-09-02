import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../data/models/ringtone.dart';

// Sentinel for copyWith nullable fields.
const Object _absent = Object();

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

  /// True only while the audio engine is actively loading or buffering — NOT when paused.
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

/// One SHARED [AudioPlayer] for all preview playback — starting a track stops the old one.
/// So two previews can never play at once, and only ONE decoder is held.
/// This screen shares the device with the feed's video pool.
class RingtonePreviewNotifier extends Notifier<RingtonePreviewState> {
  late final AudioPlayer _player;

  // Uncached, every tap re-streamed the clip -> a replay paid the round trip again, offline failed.
  // Same shape as the live-wallpaper disk cache: same package, stalePeriod, LRU bound, lifetime.
  // STATIC for the same reason: flutter_cache_manager keys its store by the Config `key`.
  // So a rebuilt notifier reads the same files, and the singleton just avoids redundant managers.
  static final CacheManager _audioCache = CacheManager(
    Config(
      'arulRingtonePreviews',
      // Published audio never changes at a given key -> this only bounds how long an unplayed clip stays.
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: _maxCacheObjects,
    ),
  );

  /// LRU bound on object COUNT — flutter_cache_manager has no byte cap.
  ///
  /// The whole catalog is 30 clips of ~0.7 MB -> this holds it several times over and never evicts.
  /// A free-storage ladder would be machinery for nothing at this size.
  /// Worst case ~84 MB, below what the live-wallpaper cache already budgets for 120 clips.
  /// Revisit if the catalog ever grows past a few hundred tracks.
  static const _maxCacheObjects = 120;

  @override
  RingtonePreviewState build() {
    _player = AudioPlayer();

    // Mirror player state changes into Riverpod state.
    _player.playerStateStream.listen((ps) {
      if (ps.processingState == ProcessingState.completed) {
        // Track finished -> return to idle so the card resets to ▶.
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

  /// Toggle play/pause for [ringtone]; a different active track is stopped first.
  /// An empty audio key sets [hasError] so the screen can toast "Preview not available yet".
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

      // Serve from disk when the clip is there -> a track previewed earlier starts instantly, offline.
      // getSingleFile hits the cache or downloads once -> the FIRST play fills it as a side effect.
      // On ANY cache-backend failure — no path_provider, a full disk, a corrupt store — stream instead.
      // Preview must never break because caching did.
      String? localPath;
      try {
        localPath = (await _audioCache.getSingleFile(url)).path;
      } catch (e) {
        debugPrint('[RingtonePreview] audio cache unavailable, streaming: $e');
      }

      // A cache MISS awaits a full download — a window wide enough to tap another row.
      // That tap already moved `currentId` -> completing here starts the WRONG track. Drop it.
      if (state.currentId != ringtone.id) return;

      // Names the source -> "did the cache engage on this device?" is answerable from logcat.
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
      // A failure belonging to a track the user tapped away from must not toast over the new one.
      if (state.currentId != ringtone.id) return;
      state = const RingtonePreviewState(hasError: true);
    }
  }

  /// Stop playback and reset to idle, on any tab or route change away from Ringtones.
  /// The IndexedStack keeps the screen ALIVE -> audio must be stopped explicitly, never left behind.
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

final ringtonePreviewProvider =
    NotifierProvider<RingtonePreviewNotifier, RingtonePreviewState>(
      RingtonePreviewNotifier.new,
    );
