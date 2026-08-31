import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/app_config_model.dart';
import '../../../theme/arul_tokens.dart';
import '../../ringtones/providers/ringtone_preview_provider.dart';
import '../../wallpapers/data/feed_video_player.dart';

/// A resolved onboarding clip: which language won and where its bytes are.
@immutable
class OnboardingVideoSource {
  const OnboardingVideoSource({required this.lang, required this.url});

  /// The language actually being shown — NOT necessarily the one asked for.
  /// A link for a language with no cut yet (`hi`, until its dub lands) resolves
  /// to `en`, and analytics reports what was really played.
  final String lang;
  final String url;

  @override
  bool operator ==(Object other) =>
      other is OnboardingVideoSource && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Which cuts exist on the CDN when `app_config` has nothing to say.
///
/// The remote list is authoritative; this is only the offline / first-launch
/// answer. `hi` is deliberately absent — the app ships six locales but only
/// five cuts have been produced, and a Hindi link must fall back to English
/// rather than request a key that 404s.
const _defaultLangs = <String>['en', 'ta', 'te', 'kn', 'ml'];

/// ONE bundled shutter frame for every language.
///
/// The cuts are the same footage with re-voiced audio, so their opening frames
/// measure ~41 dB PSNR against each other — the lip-sync differences are
/// invisible at this size, and per-language posters cost 38 KB to ship five
/// pictures of the same thing. (The English cut is the 13.1 s master rather
/// than a dub, so it diverges more; it still only shows until the texture
/// reveals, which is the entire life of this image.)
const _poster = 'assets/images/onboarding/poster.webp';

/// Resolves the clip for [languageCode], or null when onboarding video is off.
///
/// Reads `feature_flags.onboarding_video` so the whole feature — the kill
/// switch, the cache-busting version, and the set of languages that exist —
/// moves without an app release. Shipping the Hindi dub is then an upload plus
/// a CMS edit, which is the entire reason the MP4s are not bundled.
OnboardingVideoSource? resolveOnboardingVideo(
  AppConfigModel? config,
  String languageCode,
) {
  final flag = config?.featureFlags['onboarding_video'];
  final map = flag is Map ? flag : const {};

  // Absent config must not gate the feature off: a cold start reaches the
  // paywall before /config has landed on a slow connection, and a blank screen
  // where the brand block used to be would be worse than either outcome.
  if (map['enabled'] == false) return null;
  if (AppConfig.cdnBaseUrl.isEmpty) return null;

  final langs = switch (map['langs']) {
    final List<dynamic> l when l.isNotEmpty => l.whereType<String>().toList(),
    _ => _defaultLangs,
  };
  // The ladder: the language the link asked for, then English, then nothing at
  // all — the caller puts the brand lockup back. Never a broken box.
  final lang = langs.contains(languageCode)
      ? languageCode
      : (langs.contains('en') ? 'en' : null);
  if (lang == null) return null;

  final version = map['version'];
  // `?v=` rather than a purge — the same cache discipline the catalog uses.
  final query = version == null ? '' : '?v=$version';
  return OnboardingVideoSource(
    lang: lang,
    url: '${AppConfig.cdnBaseUrl}/onboarding/$lang.mp4$query',
  );
}

/// The onboarding clip on the trial screen — and ONLY there.
///
/// It takes the place of the paywall's PREMIUM / ARUL brand lockup, which is
/// set in Cinzel: a Latin-subset face that cannot render Tamil, Telugu, Kannada
/// or Malayalam at all. The screen is English by decision, so this card is the
/// only thing on it that can speak the language the ad was tapped in.
///
/// Plays WITH SOUND (owner's call): it is a voiceover pitch, and silent it
/// carries no message. That makes it the one player in the app created with
/// `audio: true` — everything in the feed stays muted and focus-free. A mute
/// control is always on screen, and any ringtone preview is stopped first so
/// two audio sources can never overlap.
///
/// Poster-first, exactly like [VideoBackground] and the feed's live cards: the
/// bundled frame paints immediately and stays MOUNTED underneath, so a decoder
/// that never starts leaves a still image rather than a black rectangle.
class ArulOnboardingVideoCard extends ConsumerStatefulWidget {
  const ArulOnboardingVideoCard({super.key, required this.source});

  final OnboardingVideoSource source;

  @override
  ConsumerState<ArulOnboardingVideoCard> createState() =>
      _ArulOnboardingVideoCardState();
}

class _ArulOnboardingVideoCardState
    extends ConsumerState<ArulOnboardingVideoCard>
    with WidgetsBindingObserver {
  FeedVideoPlayerPool? _pool;
  FeedVideoPlayer? _player;
  bool _ready = false;
  bool _muted = false;
  bool _started = false;

  /// Whether this route is the visible one — see [didChangeDependencies].
  /// Seeded true so the first callback, which always fires before a player
  /// exists, cannot register as a change.
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
  }

  /// A deferred delivery (Play referrer, GA4F, the Meta SDK) can resolve the
  /// language SECONDS after launch — after a fast user is already looking at
  /// this card. The parent re-resolves on every locale change, so a new URL
  /// here means the link's real language finally arrived: swap the media on the
  /// surviving player rather than tearing the decoder down.
  @override
  void didUpdateWidget(ArulOnboardingVideoCard old) {
    super.didUpdateWidget(old);
    if (old.source.url != widget.source.url) {
      setState(() => _ready = false);
      unawaited(_open());
    }
  }

  /// Pause when this route stops being the visible one.
  ///
  /// Leaving `/premium` disposes the card, which now really does release the
  /// player — but a route pushed OVER it (the policy reader, say) leaves the
  /// card mounted and a voice talking behind a screen the user is reading.
  /// `TickerMode` is exactly the signal: a `ModalRoute` mutes it once it is
  /// fully covered, and leaves it ON for a bottom sheet, which is what the UPI
  /// picker is — the clip is still half on screen there and should keep going.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    unawaited(visible ? _player?.play() : _player?.pause());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_player?.pause());
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // Deliberately does NOT auto-resume. Unlike a muted background loop,
        // this one talks: coming back from the UPI app or the notification
        // shade to a voice starting again mid-sentence is worse than a paused
        // frame the user can restart.
        break;
    }
  }

  Future<void> _init() async {
    // One shared AudioPlayer drives every ringtone preview; if one is running,
    // the two voices would play over each other.
    unawaited(ref.read(ringtonePreviewProvider.notifier).stop());

    final pool = FeedVideoPlayerPool();
    _pool = pool;
    // The ONLY `audio: true` player in the app.
    final player = await pool.create(audio: true);
    // Null = no platform side (headless widget test). The poster below is a
    // complete rendering on its own, so there is nothing to fall back to.
    if (player == null || !mounted) {
      await pool.dispose();
      return;
    }
    _player = player
      ..onEnded = _onEnded
      ..firstFrame.addListener(_onFirstFrame);
    await _open();
  }

  Future<void> _open() async {
    // looping: false — a 15s pitch has an ending, and only a non-looping open
    // can ever report it.
    await _player?.open(widget.source.url, playWhenReady: true, looping: false);
  }

  void _onFirstFrame() {
    final player = _player;
    if (player == null || !player.firstFrame.value || !mounted) return;
    if (!_ready) setState(() => _ready = true);
    if (!_started) {
      _started = true;
      _track('onboarding_video_start');
    }
  }

  void _onEnded() => _track('onboarding_video_complete');

  /// GA4 only. These are not on [postHogAllowedEvents] and are not a Meta star
  /// event, and none of them is a conversion — `trial_started` remains the
  /// single source for that (CLAUDE.md §3).
  void _track(String event) => ref
      .read(analyticsServiceProvider)
      .track(event, properties: {'lang': widget.source.lang});

  Future<void> _toggleMute() async {
    ArulHaptics.tap();
    final next = !_muted;
    setState(() => _muted = next);
    await _player?.setVolume(next ? 0 : 1);
    if (next) _track('onboarding_video_muted');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final player = _player;
    _player = null;
    player?.firstFrame.removeListener(_onFirstFrame);
    player?.onEnded = null;
    // Releases the native player, its surface and the audio focus it holds.
    unawaited(_pool?.dispose());
    _pool = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Padding(
      // Exactly the gutters and bottom gap the brand lockup used, so the gold
      // hairline below stays on the rhythm the handoff set.
      padding: const EdgeInsets.fromLTRB(
        20,
        0,
        20,
        ArulTokens.paywallBrandBottomPadding,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ArulTokens.paywallGoldSoft),
          ),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The shutter. Frame 0 of the very file playing above it, so
                // the reveal needs no crossfade — and it stays MOUNTED, so a
                // decoder that drops can never expose bare colour.
                const Image(
                  image: AssetImage(_poster),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                ),

                if (_ready && player != null)
                  ValueListenableBuilder<Size?>(
                    valueListenable: player.videoSize,
                    builder: (context, size, _) {
                      if (size == null || size.width <= 0 || size.height <= 0) {
                        return const SizedBox.shrink();
                      }
                      // A raw Texture does not cover-fit itself.
                      return ClipRect(
                        child: FittedBox(
                          fit: BoxFit.cover,
                          clipBehavior: Clip.hardEdge,
                          child: SizedBox(
                            width: size.width,
                            height: size.height,
                            child: Texture(textureId: player.textureId),
                          ),
                        ),
                      );
                    },
                  ),

                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _MuteButton(muted: _muted, onTap: _toggleMute),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Always visible, never a hover/idle reveal: the clip starts audible, so the
/// way to silence it has to be on screen the moment it does.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: muted ? 'Unmute video' : 'Mute video',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: ArulTokens.minHitTarget,
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xB32E1D14),
              ),
              child: Icon(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                size: 16,
                color: ArulTokens.paywallOnCta,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
