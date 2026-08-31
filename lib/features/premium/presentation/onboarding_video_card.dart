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
/// The cuts are the same footage with re-voiced audio, so their opening frames
/// measure ~41 dB PSNR against each other — the lip-sync differences are
/// invisible at this size, and per-language posters cost 38 KB to ship five
/// pictures of the same thing. (The English cut is the 13.1 s master rather
/// than a dub, so it diverges more; it still only shows until the texture
/// reveals, which is the entire life of this image.)
const _poster = 'assets/images/onboarding/poster.webp';

/// The onboarding clip on the trial screen — and ONLY there.
///
/// It takes the place of the paywall's PREMIUM / ARUL brand lockup, which is
/// set in Cinzel: a Latin-subset face that cannot render Tamil, Telugu, Kannada
/// or Malayalam at all. The screen is English by decision, so this card is the
/// only thing on it that can speak the language the ad was tapped in.
///
/// Plays WITH SOUND and on a LOOP (owner's calls): it is a voiceover pitch, and
/// silent it carries no message. That makes it the one player in the app
/// created with `audio: true` — everything in the feed stays muted and
/// focus-free. A mute control is always on screen.
///
/// **This widget does not own the player.** [PremiumScreen] creates it and
/// opens the media the instant `/premium` is entered, in parallel with the
/// `GET /me` the screen would otherwise have waited for before this card could
/// even mount — that round trip, plus a platform-channel `create`, plus the
/// fetch, used to run strictly one after another, which is the whole reason the
/// poster sat there. Here the card only attaches, plays and reveals.
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
  /// Seeded true so the first callback, which always fires before a player
  /// exists, cannot register as a change.
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach();
  }

  /// The player can arrive AFTER this card mounts (the warm-up lost the race
  /// with `/me`), and the source can change under it when a deferred delivery
  /// finally reports the ad's language — [PremiumScreen] re-opens the media on
  /// the surviving player and hands the new source down here.
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
    // Opened with playWhenReady false so a warm-up can never play audio at a
    // user who is not looking at this card (a non-trial-eligible one never sees
    // it at all). Playing is this widget's job, and only once it is on screen.
    unawaited(player.setVolume(_muted ? 0 : 1));
    if (_visible) unawaited(player.play());
  }

  /// Pause when this route stops being the visible one.
  ///
  /// Leaving `/premium` disposes the screen, which releases the player — but a
  /// route pushed OVER it (the policy reader, say) leaves this mounted and a
  /// voice talking behind a screen the user is reading. `TickerMode` is exactly
  /// the signal: a `ModalRoute` mutes it once fully covered, and leaves it ON
  /// for a bottom sheet, which is what the UPI picker is — the clip is still
  /// half on screen there and should keep going.
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
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // Deliberately does NOT auto-resume. Unlike a muted background loop,
        // this one talks: coming back from the UPI app or the notification
        // shade to a voice starting again mid-sentence is worse than a paused
        // frame the user can restart.
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

  /// GA4 only. Not on [postHogAllowedEvents], not a Meta star event, and not a
  /// conversion — `trial_started` remains the single source for that
  /// (CLAUDE.md §3). There is deliberately no "completed" event: the clip
  /// LOOPS, and a looping player never reaches `STATE_ENDED`.
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
    // The player belongs to PremiumScreen — pausing here keeps a torn-down card
    // from leaving a voice running during the frame before the screen's own
    // dispose releases it.
    unawaited(widget.player?.pause());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return Padding(
      // Same gutters as the offer panel above it, so the two read as one
      // column rather than two differently-indented blocks.
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.paywallPanelInset,
        10,
        ArulTokens.paywallPanelInset,
        ArulTokens.paywallBrandBottomPadding,
      ),
      // Full width at the clip's OWN 16:9, on every screen. The frame is never
      // cropped and never scaled down to make room — owner's call, and the
      // right one: a short screen was being paid for out of the clip, which
      // turned a talking head into a letterbox band of forehead. Room comes
      // from the chrome around it instead (`dense` in paywall_view.dart), so
      // the viewer sees the same framing everywhere and only the padding, the
      // ornament and the price lockup shrink.
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
                  // The shutter. Stays MOUNTED under the texture, so a
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
