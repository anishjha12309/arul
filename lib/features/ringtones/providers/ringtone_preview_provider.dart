import 'package:flutter/foundation.dart';
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
      debugPrint('[RingtonePreview] loading $url');
      await _player.setUrl(url);
      await _player.play();
    } catch (e, st) {
      debugPrint('[RingtonePreview] error: $e\n$st');
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
