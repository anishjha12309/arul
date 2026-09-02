import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../../wallpapers/data/feed_video_player.dart';
import '../domain/onboarding_video.dart';

/// ONE bundled shutter frame for every language.
///
/// The cuts are the same footage re-voiced -> their opening frames measure ~41 dB PSNR apart.
/// Per-language posters would cost 38 KB to ship five pictures of the same thing.
/// The English cut is the master, not a dub, so it diverges more — but it only shows until reveal.
const _poster = 'assets/images/onboarding/poster.webp';

/// The onboarding clip on the trial screen — and ONLY there.
///
/// It replaces the PREMIUM/ARUL lockup, set in Cinzel, which renders no Indic script at all.
/// The screen is English by decision -> this card is the only thing that speaks the ad's language.
/// It is a voiceover pitch and carries no message silent -> plays WITH SOUND, on a LOOP.
/// That makes it the one player created with `audio: true` — the feed stays muted and focus-free.
/// A mute control is always on screen.
/// **This widget does not own the player** — [PremiumScreen] creates and opens it on route entry.
/// That runs in PARALLEL with `GET /me`, which the screen would otherwise have waited on.
/// Serialised, the round trip plus a channel create plus the fetch is why the poster used to sit.
/// Here the card only attaches, plays and reveals.
class ArulOnboardingVideoCard extends ConsumerStatefulWidget {
  const ArulOnboardingVideoCard({
    super.key,
    required this.player,
    required this.source,
  });

  /// Null while the warm-up is still in flight — the poster covers that.
  final FeedVideoPlayer? player;
  final OnboardingVideoSource source;

  @override
  ConsumerState<ArulOnboardingVideoCard> createState() =>
      _ArulOnboardingVideoCardState();
}

class _ArulOnboardingVideoCardState
    extends ConsumerState<ArulOnboardingVideoCard>
    with WidgetsBindingObserver {
  bool _ready = false;
  bool _muted = false;
  bool _started = false;

  /// Whether this route is the visible one — see [didChangeDependencies].
  /// Seeded TRUE -> the first callback, which fires before a player exists, is not a change.
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  /// The player can arrive AFTER this card mounts — the warm-up lost the race with `/me`.
  /// The source can change under it when a deferred delivery finally reports the ad's language.
  /// [PremiumScreen] re-opens the media on the SURVIVING player and hands the new source down.
  @override
  void didUpdateWidget(ArulOnboardingVideoCard old) {
    super.didUpdateWidget(old);
    if (old.player != widget.player) {
      old.player?.firstFrame.removeListener(_onFirstFrame);
      _attach();
    } else if (old.source != widget.source) {
      setState(() => _ready = false);
      unawaited(widget.player?.play());
    }
  }

  void _attach() {
    final player = widget.player;
    if (player == null) return;
    if (player.firstFrame.value) {
      _ready = true;
      _markStarted();
    } else {
      player.firstFrame.addListener(_onFirstFrame);
    }
    // Opened with playWhenReady false -> a warm-up never plays audio at someone not looking.
    // Playing is this widget's job, and only once the card is on screen.
    unawaited(player.setVolume(_muted ? 0 : 1));
    if (_visible) unawaited(player.play());
  }

  /// Pause when this route stops being the visible one.
  ///
  /// A route pushed OVER `/premium` leaves this mounted and a voice talking behind what is read.
  /// `TickerMode` is exactly the signal: a `ModalRoute` mutes it once FULLY covered.
  /// It stays ON for a bottom sheet — the UPI picker — where the clip is still half on screen.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    unawaited(visible ? widget.player?.play() : widget.player?.pause());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(widget.player?.pause());
      case AppLifecycleState.resumed:
        // Resumes IN PLACE (owner's call, reversing the old never-auto-resume rule).
        // The common return here is from the UPI app mid-checkout, and a frozen frame on the way
        // back read as broken -> a mid-sentence pickup is the accepted cost of a loop that holds.
        // `_visible` gates it: covered by a pushed route, TickerMode owns playback, not this.
        if (_visible) unawaited(widget.player?.play());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onFirstFrame() {
    final player = widget.player;
    if (player == null || !player.firstFrame.value || !mounted) return;
    if (!_ready) setState(() => _ready = true);
    _markStarted();
  }

  void _markStarted() {
    if (_started) return;
    _started = true;
    _track('onboarding_video_start');
  }

  /// GA4 only — off [postHogAllowedEvents], not a Meta ★, not a conversion (`trial_started` is).
  /// No "completed" event: the clip LOOPS, and a looping player never reaches `STATE_ENDED`.
  void _track(String event) => ref
      .read(analyticsServiceProvider)
      .track(event, properties: {'lang': widget.source.lang});

  Future<void> _toggleMute() async {
    ArulHaptics.tap();
    final next = !_muted;
    setState(() => _muted = next);
    await widget.player?.setVolume(next ? 0 : 1);
    if (next) _track('onboarding_video_muted');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.player?.firstFrame.removeListener(_onFirstFrame);
    // The player belongs to PremiumScreen -> pause here, or a torn-down card leaves a voice running.
    unawaited(widget.player?.pause());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return Padding(
      // Same gutters as the offer panel above -> the two read as one column, not two indents.
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.paywallPanelInset,
        10,
        ArulTokens.paywallPanelInset,
        ArulTokens.paywallBrandBottomPadding,
      ),
      // Full width at the clip's OWN 16:9 on every screen — never cropped, never scaled to fit.
      // Paying for a short screen out of the clip turned a talking head into a band of forehead.
      // Room comes from the chrome instead (`dense` in paywall_view.dart) -> one framing everywhere.
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: SizedBox(
          key: const Key('onboarding-video-frame'),
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: ArulTokens.paywallGoldSoft),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The shutter stays MOUNTED under the texture -> a dropped decoder shows no bare colour.
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
                        if (size == null ||
                            size.width <= 0 ||
                            size.height <= 0) {
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
                    right: 4,
                    bottom: 4,
                    child: _MuteButton(muted: _muted, onTap: _toggleMute),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The clip starts AUDIBLE -> the way to silence it is on screen from the first frame, always.
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
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xB32E1D14),
              ),
              child: Icon(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                size: 15,
                color: ArulTokens.paywallOnCta,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
