import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/build_info.dart';
import '../../../data/models/ringtone.dart';

const Object _absent = Object();

enum RingtonePreviewIssue { none, unavailable, muted }

class RingtonePreviewState {
  const RingtonePreviewState({
    this.currentId,
    this.isPlaying = false,
    this.isBuffering = false,
    this.issue = RingtonePreviewIssue.none,
  });

  final String? currentId;
  final bool isPlaying;

  final bool isBuffering;

  final RingtonePreviewIssue issue;

  bool get hasError => issue == RingtonePreviewIssue.unavailable;

  bool get isMuted => issue == RingtonePreviewIssue.muted;

  bool isPlayingId(String id) => currentId == id && isPlaying;

  bool isLoadingId(String id) => currentId == id && isBuffering;

  RingtonePreviewState copyWith({
    Object? currentId = _absent,
    bool? isPlaying,
    bool? isBuffering,
    RingtonePreviewIssue? issue,
  }) => RingtonePreviewState(
    currentId: identical(currentId, _absent)
        ? this.currentId
        : currentId as String?,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    issue: issue ?? this.issue,
  );
}

/// One SHARED [AudioPlayer] for all preview playback — starting a track stops the old one.
/// So two previews can never play at once, and only ONE decoder is held.
/// This screen shares the device with the feed's video pool.
///
/// A tap to a different row while one plays cross-fades on this SAME player rather than hard
/// cutting: the outgoing clip ramps to silence while the incoming one loads, then the incoming
/// one ramps up from silence. A true overlap would need a second decoder this app does not spend.
class RingtonePreviewNotifier extends Notifier<RingtonePreviewState> {
  late final AudioPlayer _player;

  /// Single-flight session setup, awaited before the first play so the focus
  /// request cannot race it — unconfigured, `setActive` falls back to
  /// [AudioSessionConfiguration.music], which is the permanent gain we are avoiding.
  Future<void>? _sessionReady;

  AppLifecycleListener? _lifecycle;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  StreamSubscription<PlayerState>? _playerStateSub;

  /// Bumped by every action that decides what the player's volume should be next -> a ramp whose
  /// captured generation has gone stale stops writing volume, whether it lost the race to a new
  /// tap, a fresh interruption, or a plain stop.
  int _fadeGeneration = 0;

  /// True while the CURRENT paused state was caused by an interruption, not the user -> only then
  /// does an interruption-end event resume playback on its own.
  bool _pausedByInterruption = false;

  /// True while a transient "can duck" loss has this player quieted -> restored to full volume
  /// the moment that interruption ends.
  bool _duckedByInterruption = false;

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

  /// W3's ramp shape — ~10ms steps over 150ms, small enough that a plain async loop beats pulling
  /// in a real animation controller for a provider with no BuildContext.
  static const _fadeDuration = Duration(milliseconds: 150);
  static const _fadeStepInterval = Duration(milliseconds: 10);

  /// Android's own convention for a duckable loss — quiet enough to concede the moment, not silent.
  static const _duckVolume = 0.3;

  @override
  RingtonePreviewState build() {
    _player = AudioPlayer();
    _sessionReady = _configureSession();

    _lifecycle = AppLifecycleListener(
      onStateChange: (lifecycle) {
        if (lifecycle == AppLifecycleState.paused ||
            lifecycle == AppLifecycleState.hidden) {
          unawaited(stop());
        }
      },
    );

    _playerStateSub = _player.playerStateStream.listen((ps) {
      if (ps.processingState == ProcessingState.completed) {
        // Track finished -> return to idle so the card resets to ▶. Nothing left to fade, and
        // interruption bookkeeping about a track that is now gone would only mislead the next one.
        _pausedByInterruption = false;
        _duckedByInterruption = false;
        _fadeGeneration++;
        unawaited(_releaseFocus());
        state = const RingtonePreviewState();
        return;
      }
      final buffering =
          ps.processingState == ProcessingState.loading ||
          ps.processingState == ProcessingState.buffering;
      state = state.copyWith(isPlaying: ps.playing, isBuffering: buffering);
    });

    ref.onDispose(() {
      _lifecycle?.dispose();
      unawaited(_interruptionSub?.cancel());
      unawaited(_becomingNoisySub?.cancel());
      unawaited(_playerStateSub?.cancel());
      unawaited(_releaseFocus());
      _player.dispose();
    });
    return const RingtonePreviewState();
  }

  /// TRANSIENT focus, not the `music()` default GAIN.
  ///
  /// A preview is a few seconds of audition, so it must borrow the output and hand it
  /// back: `GAIN_TRANSIENT` pauses the user's music and Android resumes it the moment
  /// focus is abandoned, where a permanent gain kills it for the rest of the session.
  /// Attributes stay media/music — the clip rides the media volume the user expects.
  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransient,
        ),
      );
      _interruptionSub = session.interruptionEventStream.listen(
        _handleInterruption,
      );
      _becomingNoisySub = session.becomingNoisyEventStream.listen(
        (_) => _handleBecomingNoisy(),
      );
    } catch (e) {
      // A session we could not configure still plays — never fail a preview on it.
      debugPrint('[RingtonePreview] audio session unavailable: $e');
    }
  }

  Future<void> _releaseFocus() async {
    try {
      await (await AudioSession.instance).setActive(false);
    } catch (e) {
      debugPrint('[RingtonePreview] focus release failed: $e');
    }
  }

  /// Focus taken by another app — a call, another player starting, a headphone unplug — all
  /// arrive as one [AudioInterruptionEvent] stream. `unknown` is the package's own word for a
  /// loss "possibly indefinite" (confirmed against the installed audio_session 0.2.4 source:
  /// Android's permanent AUDIOFOCUS_LOSS maps to `unknown` and never sends a matching end event),
  /// so that branch stops outright rather than waiting for an end that is not coming.
  ///
  /// Kept instant, not routed through the W3 ramp: Android expects compliance right away, and a
  /// polish fade belongs to the user-facing taps in [toggle], not to a system interruption.
  void _handleInterruption(AudioInterruptionEvent event) {
    try {
      if (event.begin) {
        debugPrint('[RingtonePreview] interruption begin ${event.type.name}');
        // A ramp already in flight must not fight this decision for the volume knob.
        _fadeGeneration++;
        switch (event.type) {
          case AudioInterruptionType.duck:
            if (state.isPlaying) {
              _duckedByInterruption = true;
              unawaited(_setVolumeSafe(_duckVolume));
            }
            break;
          case AudioInterruptionType.pause:
            if (state.isPlaying) {
              _pausedByInterruption = true;
              unawaited(_player.pause());
            }
            break;
          case AudioInterruptionType.unknown:
            unawaited(stop());
            break;
        }
      } else {
        if (_duckedByInterruption) {
          _duckedByInterruption = false;
          unawaited(_setVolumeSafe(1));
        }
        if (_pausedByInterruption) {
          _pausedByInterruption = false;
          debugPrint('[RingtonePreview] interruption end resume');
          unawaited(_player.play());
        } else {
          debugPrint('[RingtonePreview] interruption end stay');
        }
      }
    } catch (e) {
      debugPrint('[RingtonePreview] interruption handling failed: $e');
    }
  }

  /// Headphones (or a Bluetooth device) gone mid-preview -> pause rather than blast the speaker.
  /// There is no matching "noisy ended" event, so this behaves like a user pause, not a resumable
  /// one: the row stays paused until the user taps it again.
  void _handleBecomingNoisy() {
    try {
      debugPrint('[RingtonePreview] becoming noisy -> pause');
      _fadeGeneration++;
      _pausedByInterruption = false;
      _duckedByInterruption = false;
      if (state.isPlaying) {
        unawaited(_player.pause());
        unawaited(_releaseFocus());
      }
    } catch (e) {
      debugPrint('[RingtonePreview] becoming-noisy handling failed: $e');
    }
  }

  /// Whether starting a preview right now would be inaudible.
  ///
  /// Only STREAM_MUSIC's own level counts. Android's ringer mode (silent/vibrate) gates the
  /// ringtone and notification streams, never music — a user who silenced notifications but kept
  /// their media volume up must still hear this preview, so ringer mode plays no part in the
  /// answer. `getStreamVolume`/`getStreamMaxVolume`/`getRingerMode` are marked "(UNTESTED)" in the
  /// audio_session source itself, so any failure here answers `false` — a flaky probe must never
  /// block a preview the user could actually have heard.
  Future<bool> _isMediaStreamMuted() async {
    try {
      final volume = await AndroidAudioManager().getStreamVolume(
        AndroidStreamType.music,
      );
      return volume <= 0;
    } catch (e) {
      debugPrint('[RingtonePreview] volume probe unavailable: $e');
      return false;
    }
  }

  /// Writes one volume value, never letting a platform hiccup here reach the caller -> a failed
  /// step just holds the last volume the player actually accepted.
  Future<void> _setVolumeSafe(double volume) async {
    try {
      await _player.setVolume(volume);
    } catch (e) {
      debugPrint('[RingtonePreview] setVolume failed: $e');
    }
  }

  /// Steps the shared player's volume from [from] to [to] over [_fadeDuration]. Bails the instant
  /// [generation] falls behind [_fadeGeneration] -> a ramp belonging to a track the user has
  /// tapped away from, or that a fresh interruption has just overridden, can never write volume
  /// for whatever the player carries now.
  Future<void> _rampVolume(double from, double to, int generation) async {
    final steps =
        _fadeDuration.inMilliseconds ~/ _fadeStepInterval.inMilliseconds;
    for (var i = 1; i <= steps; i++) {
      if (generation != _fadeGeneration) return;
      await _setVolumeSafe(from + (to - from) * (i / steps));
      if (i < steps) await Future<void>.delayed(_fadeStepInterval);
    }
  }

  /// Ramps the outgoing clip to silence. Skipped under [reduceMotion] -> that flag covers audio
  /// transitions here too, so a low-tier phone or a11y `disableAnimations` gets the original hard
  /// stop back.
  Future<void> _fadeOut({
    required int generation,
    required bool reduceMotion,
  }) async {
    if (reduceMotion) return;
    debugPrint('[RingtonePreview] fade out ${_fadeDuration.inMilliseconds}ms');
    await _rampVolume(_player.volume, 0, generation);
  }

  /// Ramps the incoming clip up from silence, then logs completion — gated on [generation] still
  /// being current, so a track the user has already tapped away from never claims it finished.
  Future<void> _fadeIn({
    required int generation,
    required bool reduceMotion,
    required String id,
  }) async {
    if (reduceMotion) {
      await _setVolumeSafe(1);
    } else {
      debugPrint('[RingtonePreview] fade in ${_fadeDuration.inMilliseconds}ms');
      await _rampVolume(_player.volume, 1, generation);
    }
    if (generation == _fadeGeneration) {
      debugPrint('[RingtonePreview] fade complete $id');
    }
  }

  /// Toggle play/pause for [ringtone]. A different track cross-fades rather than being
  /// hard-stopped; an empty audio key, a fetch failure, or a muted stream sets
  /// [RingtonePreviewState.issue] so the screen can toast — see [RingtonePreviewIssue].
  ///
  /// [reduceMotion] lets a caller holding a BuildContext pass `context.reduceMotion` straight in.
  /// This file has none, so when it is omitted only the device-tier half of that signal is read
  /// directly ([DeviceTier.low]) — the MediaQuery half cannot reach here without one.
  Future<void> toggle(Ringtone ringtone, {bool? reduceMotion}) async {
    final reduceFx = reduceMotion ?? (DeviceQuality.resolved == DeviceTier.low);
    _pausedByInterruption = false;
    _duckedByInterruption = false;

    if (state.currentId == ringtone.id) {
      if (state.isPlaying) {
        // Visible flip leads exactly as a start does -> the icon answers the tap immediately and
        // the audio trails it out.
        state = state.copyWith(isPlaying: false);
        final generation = ++_fadeGeneration;
        await _fadeOut(generation: generation, reduceMotion: reduceFx);
        await _player.pause();
        await _releaseFocus();
      } else {
        if (await _isMediaStreamMuted()) {
          debugPrint('[RingtonePreview] muted, not starting (volume 0)');
          state = state.copyWith(issue: RingtonePreviewIssue.muted);
          return;
        }
        if (!reduceFx) await _player.setVolume(0);
        final generation = ++_fadeGeneration;
        // NEVER `await` this. just_audio's own contract: the future completes when playback
        // COMPLETES, is paused, or is stopped — immediately only if the player is already
        // playing. Awaiting it from idle parks the ramp below for the whole clip, so the preview
        // runs at the volume 0 set just above and the very first tap is SILENT. It logged as a
        // `fade in` arriving 19 s late, at the moment an interruption paused the player.
        unawaited(_player.play());
        unawaited(
          _fadeIn(
            generation: generation,
            reduceMotion: reduceFx,
            id: ringtone.id,
          ),
        );
      }
      return;
    }

    // A different row while the old one is audibly playing -> cross-fade, never a hard cut.
    // ONE shared player means a true two-clip overlap needs a second decoder this app does not
    // spend -> the old clip ramps to silence while the new one loads, then the new one ramps up
    // from silence once it is ready. No explicit stop() sits between them; just_audio's own
    // setAudioSource swap (its source docs preload as forced true while `playing`) is what
    // retires the old source the instant the new one is set.
    final outgoingId = state.isPlaying ? state.currentId : null;
    Future<void> outgoingFaded = Future<void>.value();
    if (outgoingId != null && !reduceFx) {
      debugPrint('[RingtonePreview] crossfade $outgoingId -> ${ringtone.id}');
      final outGeneration = ++_fadeGeneration;
      outgoingFaded = _fadeOut(
        generation: outGeneration,
        reduceMotion: reduceFx,
      );
    } else {
      // No ramp available -> HARD CUT, the pre-fade behaviour. Under reduceMotion `_fadeOut`
      // returns immediately, so routing the outgoing clip through it would neither fade nor stop
      // it: the old track would keep playing at full volume through the session await, the muted
      // probe and the whole cache fetch, while the lit row already showed the NEW one. That is a
      // low-tier-only path, which is exactly why the A001 walk could not see it.
      if (outgoingId != null) {
        debugPrint('[RingtonePreview] cut $outgoingId -> ${ringtone.id}');
      }
      await _player.stop();
    }

    await _sessionReady;
    state = RingtonePreviewState(currentId: ringtone.id, isBuffering: true);

    if (ringtone.audioKey.isEmpty) {
      await outgoingFaded;
      await _player.stop();
      await _releaseFocus();
      state = const RingtonePreviewState(
        issue: RingtonePreviewIssue.unavailable,
      );
      return;
    }

    if (await _isMediaStreamMuted()) {
      debugPrint('[RingtonePreview] muted, not starting (volume 0)');
      await outgoingFaded;
      await _player.stop();
      await _releaseFocus();
      state = const RingtonePreviewState(issue: RingtonePreviewIssue.muted);
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

      // The old clip's ramp overlaps this fetch -> wait for it so the shared player only ever
      // carries one audible source at a time, however long the fetch itself took.
      await outgoingFaded;

      // A cache MISS awaits a full download — a window wide enough to tap another row.
      // That tap already moved `currentId` -> completing here starts the WRONG track. Drop it.
      if (state.currentId != ringtone.id) return;

      // Names the source -> "did the cache engage on this device?" is answerable from logcat.
      debugPrint(
        '[RingtonePreview] ${localPath != null ? 'disk' : 'net'} $url',
      );
      if (!reduceFx) await _player.setVolume(0);
      if (localPath != null) {
        await _player.setFilePath(localPath);
      } else {
        await _player.setUrl(url);
      }
      if (state.currentId != ringtone.id) return;
      final generation = ++_fadeGeneration;
      // Not awaited, for the reason on the resume branch above: from idle this future does not
      // complete until the clip ends, and the ramp behind it would never run.
      unawaited(_player.play());
      unawaited(
        _fadeIn(
          generation: generation,
          reduceMotion: reduceFx,
          id: ringtone.id,
        ),
      );
    } catch (e, st) {
      debugPrint('[RingtonePreview] error: $e\n$st');
      // A failure belonging to a track the user tapped away from must not toast over the new one.
      if (state.currentId != ringtone.id) return;
      await _player.stop();
      await _releaseFocus();
      state = const RingtonePreviewState(
        issue: RingtonePreviewIssue.unavailable,
      );
    }
  }

  /// Stop playback and reset to idle, on any tab or route change away from Ringtones.
  /// The IndexedStack keeps the screen ALIVE -> audio must be stopped explicitly, never left behind.
  /// Fades first when something is audibly playing, exactly like a user pause -> a tab switch must
  /// not click.
  Future<void> stop() async {
    _pausedByInterruption = false;
    _duckedByInterruption = false;
    final wasPlaying = state.isPlaying;
    final generation = ++_fadeGeneration;
    state = const RingtonePreviewState();
    if (wasPlaying) {
      await _fadeOut(
        generation: generation,
        reduceMotion: DeviceQuality.resolved == DeviceTier.low,
      );
    }
    await _player.stop();
    await _releaseFocus();
  }

  /// Where the playing clip is, and how long it is — read-only windows onto the ONE shared player,
  /// for the row's elapsed ring.
  ///
  /// Exposed rather than mirrored into [state]: position ticks tens of times a second and the state
  /// object is what the whole list rebuilds on. The ring subscribes to this stream ALONE and
  /// repaints in isolation, so an elapsed indicator costs no row rebuilds.
  /// Still derives from the ONE `currentId` — the stream says where, [state] says which.
  Stream<Duration> get positionStream => _player.positionStream;

  /// The loaded clip's length, null until the source is prepared. Null means "no arc yet", never
  /// a guessed denominator.
  Duration? get clipDuration => _player.duration;

  /// The same length as a stream, for the beat between `play()` and the first duration landing.
  Stream<Duration?> get durationStream => _player.durationStream;

  void clearError() {
    if (state.issue != RingtonePreviewIssue.none) {
      state = state.copyWith(issue: RingtonePreviewIssue.none);
    }
  }
}

final ringtonePreviewProvider =
    NotifierProvider<RingtonePreviewNotifier, RingtonePreviewState>(
      RingtonePreviewNotifier.new,
    );
