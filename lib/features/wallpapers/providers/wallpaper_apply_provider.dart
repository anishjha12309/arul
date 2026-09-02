import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../../data/models/wallpaper.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/wallpaper_apply_service.dart';
import 'wallpaper_prefetch_provider.dart';

// Android 12+ re-extracts Material You colours on a wallpaper change and can recreate the Activity
// (flutter#133722), and the live chooser opens over us -> write these to SharedPreferences BEFORE
// the native call -> the feed restores the page instead of showing a full-screen spinner.
// Set for BOTH static and live.

const appliedWallpaperPendingKey = 'applied_wallpaper_pending';
const pendingApplyPageIndexKey = 'pending_apply_page_index';
const pendingApplyCategoryKey = 'pending_apply_category';

/// True when the pending apply was LIVE. Position restores for both kinds -> the live chooser's
/// outcome is unobservable -> only static may show an "applied" confirmation.
const pendingApplyIsLiveKey = 'pending_apply_is_live';

enum WallpaperApplyStage { preparing, downloading, applying }

sealed class WallpaperApplyState {
  const WallpaperApplyState();
}

final class WallpaperApplyIdle extends WallpaperApplyState {
  const WallpaperApplyIdle();
}

final class WallpaperApplyLoading extends WallpaperApplyState {
  const WallpaperApplyLoading({required this.stage, this.progress});

  final WallpaperApplyStage stage;

  /// 0.0–1.0 while downloading; null elsewhere -> those stages are indefinite -> the UI must show
  /// an indeterminate indicator, never a 0% bar.
  final double? progress;
}

final class WallpaperApplySuccess extends WallpaperApplyState {
  const WallpaperApplySuccess({
    required this.isLive,
    this.staticFallback = false,
  });
  final bool isLive;

  /// A LIVE wallpaper this device cannot run, applied as its own first frame instead (native
  /// [LiveApplyOutcome.staticFallback]).
  ///
  /// Live apply normally ends [WallpaperApplyIdle] with the OS chooser open -> a live Success can
  /// ONLY mean this -> it needs its own toast: "Wallpaper applied" while the motion the user picked
  /// is silently missing reads as a bug.
  final bool staticFallback;
}

final class WallpaperApplyError extends WallpaperApplyState {
  const WallpaperApplyError({
    required this.message,
    this.isNetwork = false,
    this.premiumRequired = false,
  });

  /// DIAGNOSTIC ONLY -> can be a raw `FileSystemException: …` and stays English in every locale ->
  /// never show it to a user; it exists for logs and crash reporting.
  final String message;

  /// Offline, not broken -> the UI says so and offers retry.
  final bool isNetwork;

  /// The server refused the apply: the subscription is no longer live -> a generic failure would
  /// dead-end a lapsed subscriber in English with no way to resubscribe -> route to the paywall.
  final bool premiumRequired;
}

/// The ONE temp-file name apply and share both use for a given wallpaper.
///
/// They MUST agree -> a share-only `arul-…` prefix made apply-then-share fetch the identical bytes
/// TWICE. The recipient-facing name is a share-sheet concern (`fileNameOverrides`) -> the file on
/// disk is a cache key, owned by whoever fetched it first.
String applyCacheFilename(Wallpaper w) => w.key.split('/').last;

final wallpaperApplyServiceProvider = Provider<WallpaperApplyService>(
  (ref) => CdnWallpaperApplyService(apiClient: ref.watch(apiClientProvider)),
);

class WallpaperApplyNotifier extends Notifier<WallpaperApplyState> {
  @override
  WallpaperApplyState build() => const WallpaperApplyIdle();

  /// Runs the whole apply flow.
  ///
  /// A budget SoC has only a handful of hardware codecs -> the wallpaper engine (or the OS chooser)
  /// falls back to software decode and stutters -> await [releaseVideoDecoders] immediately before
  /// the native call so the feed's ExoPlayers give theirs up.
  Future<void> apply(
    Wallpaper wallpaper, {
    required ApplyTarget target,
    int? feedPageIndex,
    String? category,
    Future<void> Function()? releaseVideoDecoders,
  }) async {
    // Re-entrancy guard -> a double-tap must not start two downloads and two native calls racing
    // to write the same temp file.
    if (state is WallpaperApplyLoading) return;

    final service = ref.read(wallpaperApplyServiceProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final isLive = wallpaper.kind == WallpaperKind.live;

    // The guard above sits ahead of two awaits (`getTemporaryDirectory`, `exists`) -> a double-tap
    // inside those milliseconds slips through -> claim the flow BEFORE the first await.
    state = const WallpaperApplyLoading(stage: WallpaperApplyStage.preparing);

    // Set when `wallpaper_apply_attempt` fires, read by the catch blocks -> a failure before that
    // line (signed-url refusal, a connection dying mid-download) has no attempt to count against ->
    // reporting one would put `wallpaper_apply_failed` outside its own denominator.
    var attempted = false;

    try {
      final filename = applyCacheFilename(wallpaper);
      final tmpDir = await getTemporaryDirectory();
      final cachedFile = File('${tmpDir.path}/$filename');

      File? file;

      if (await cachedFile.exists() && await cachedFile.length() > 0) {
        // Already fetched by a previous apply or share — e.g. the user dismissed the OEM chooser.
        file = cachedFile;
      } else {
        // The feed prefetcher already pulled this clip so the player could open a local file, and
        // apply and prefetch resolve the SAME public CDN URL -> those bytes are reusable -> copy
        // them rather than spend another 2-15 MB of the user's mobile data on a file we hold.
        final prefetched = await ref
            .read(wallpaperPrefetchServiceProvider)
            .cachedPathOrNull(await service.resolveUrl(wallpaper));
        if (prefetched != null) {
          try {
            file = await File(prefetched).copy(cachedFile.path);
          } catch (_) {
            // Evicted between the lookup and the copy -> fall through and download.
          }
        }
      }

      if (file != null) {
        // Bytes already on disk (a previous apply/share, or the prefetcher) -> the DOWNLOAD is
        // skipped, the GATE is not.
        // `/media/signed-url` is the only authoritative entitlement check (CLAUDE.md §5); the
        // client-side gate ahead of it is UX.
        // Skipping the round-trip here lets a lapsed, cancelled or refunded user re-apply anything
        // on disk indefinitely -> a cache must never become a permanent licence.
        try {
          await service.downloadUrl(wallpaper, action: MediaUseAction.apply);
        } on WallpaperApplyException catch (e) {
          // A real 403 is the gate doing its job -> rethrow so the screen routes to the paywall;
          // any other API failure on bytes we already hold must not block a paying user.
          if (e.premiumRequired) rethrow;
        } catch (e) {
          if (!isNetworkError(e)) rethrow;
          // Offline, with the file on disk from a previously-passing gate -> stranding a paying
          // user in a dead zone beats the narrow bypass, which dies with the temp directory ->
          // let it through. The one allowed pass-through.
        }
      }

      if (file == null) {
        // The GATED download URL -> Worker signed-url (live entitlement check) when the backend
        // exists, public CDN before then.
        final url = await service.downloadUrl(
          wallpaper,
          action: MediaUseAction.apply,
        );

        state = const WallpaperApplyLoading(
          stage: WallpaperApplyStage.downloading,
          progress: 0,
        );
        file = await service.downloadFile(url, filename, (p) {
          state = WallpaperApplyLoading(
            stage: WallpaperApplyStage.downloading,
            progress: p,
          );
        });
      }

      state = const WallpaperApplyLoading(stage: WallpaperApplyStage.applying);

      // Denominator of the apply funnel -> download and the authoritative gate are both behind us
      // -> what fails past this line is the native call or the OS, which is exactly the ratio
      // `wallpaper_applied / wallpaper_apply_attempt` measures.
      // GA4-only, off the PostHog allow-list -> attempts are volume, and GA4 takes volume at 100%.
      analytics.track(
        'wallpaper_apply_attempt',
        properties: _applyProps(wallpaper, target: target),
      );
      attempted = true;

      // Persist restore state BEFORE the native call -> see the flag notes at the top.
      if (feedPageIndex != null) {
        await prefs.setInt(pendingApplyPageIndexKey, feedPageIndex);
      }
      if (category != null) {
        await prefs.setString(pendingApplyCategoryKey, category);
      }
      await prefs.setBool(pendingApplyIsLiveKey, isLive);
      await prefs.setBool(appliedWallpaperPendingKey, true);

      if (isLive) {
        // The OS chooser opens for EVERY live apply and the final "Set wallpaper" tap happens in an
        // activity we cannot see -> finish IDLE, never a false "applied" confirmation.
        // Its preview engine claims a hardware MediaCodec -> a still-held feed pool starves it into
        // a frozen or black wallpaper on a decoder-constrained SoC -> release the decoders first.
        if (releaseVideoDecoders != null) await releaseVideoDecoders();
        final live = await service.applyLiveWallpaper(file, target);

        if (live.outcome == LiveApplyOutcome.staticFallback) {
          // The device cannot run live wallpapers at all, so native already applied the clip's
          // first frame -> nothing is pending and nothing is unobservable -> take the STATIC
          // semantics wholesale.
          // The flags went down with `pending_apply_is_live: true` -> leaving them has
          // `apply_restore.dart` read a finished apply as a chooser still open -> clear them.
          // Tripwire for the whole feature -> this event's rate against `wallpaper_apply_attempt`
          // where type=live says whether the fallback ever fires on mainstream devices; expect ~0.
          analytics.track(
            'wallpaper_apply_live_fallback',
            properties: {
              ..._applyProps(wallpaper, target: target),
              'reason': live.reason ?? 'unknown',
            },
          );
          await _clearPending(prefs);
          _trackApplied(
            analytics,
            wallpaper,
            target: target,
            confirmed: true,
            fallback: true,
          );
          state = const WallpaperApplySuccess(
            isLive: true,
            staticFallback: true,
          );
          return;
        }

        _trackApplied(analytics, wallpaper, target: target, confirmed: false);
        // Flags stay set -> a chooser-caused recreate restores position; otherwise the feed
        // consumes them on the next resume.
        state = const WallpaperApplyIdle();
        return;
      }

      // Static. The apply can recreate the Activity -> await the decoder release first, so a
      // completed disposal cannot race Flutter teardown.
      if (releaseVideoDecoders != null) await releaseVideoDecoders();
      await service.applyStaticWallpaper(file, target);

      // We got here -> no OS restart happened -> clear the flags and confirm inline.
      await _clearPending(prefs);
      _trackApplied(analytics, wallpaper, target: target, confirmed: true);
      state = const WallpaperApplySuccess(isLive: false);
    } on WallpaperApplyException catch (e) {
      await _clearPending(prefs);
      if (e.premiumRequired) {
        // Not a defect: the live entitlement check caught a lapsed or refunded subscription ->
        // refresh the stale client snapshot that let the user get this far, then let the screen
        // route to the paywall. Not a failure event either -> it has its own `apply_blocked_premium`.
        ref.invalidate(entitlementDetailProvider);
      } else if (attempted) {
        _trackFailed(
          analytics,
          wallpaper,
          target: target,
          code: e.code ?? 'unknown',
        );
      }
      state = WallpaperApplyError(
        message: e.message,
        premiumRequired: e.premiumRequired,
      );
    } catch (e) {
      await _clearPending(prefs);
      // Offline (the download) is the common case here and is not a bug -> the UI must never print
      // "ClientException: Failed host lookup".
      final network = isNetworkError(e);
      if (attempted) {
        _trackFailed(
          analytics,
          wallpaper,
          target: target,
          code: network ? 'network' : 'unknown',
        );
      }
      state = WallpaperApplyError(message: e.toString(), isNetwork: network);
    }
  }

  /// Shared property block for the apply funnel, so attempt and completion join on the same keys.
  ///
  /// `wallpaper_id` + `category` is Arul's convention — category is this app's browse axis, so
  /// "which collections convert" is answerable off these events alone.
  /// Pakiza has no category axis and carries only `type` -> unifying the two breaks every saved
  /// dashboard in both projects -> keep each app's own convention.
  /// `type` is spelled as `wallpaper_shared` spells it (`kind.name` → `image`/`live`) -> the two
  /// funnels join on it. It stays a rendering hint, never a browse axis (CLAUDE.md §5b) — never
  /// group by it the way `category` is grouped.
  Map<String, Object?> _applyProps(
    Wallpaper wallpaper, {
    required ApplyTarget target,
  }) => {
    'wallpaper_id': wallpaper.id,
    'category': wallpaper.category,
    'type': wallpaper.kind.name,
    'target': target.name,
  };

  /// Fires `wallpaper_applied` — the primary value moment, one of the few events PostHog is billed
  /// for.
  ///
  /// Static returns from a native call that worked or threw, so success is a fact; every live apply
  /// ends at an unobservable chooser tap -> the event fires there anyway (suppressing it under-counts
  /// live and breaks comparison with Pakiza, which fires on chooser-open too) -> [confirmed] marks
  /// which it was, and filtering `confirmed = true` recovers the strict count.
  /// Never claim a completion rate off the unfiltered number.
  /// [fallback] marks the ONE confirmed live apply — the device could not run live, so its first
  /// frame was applied -> without it "`confirmed` is true only on a static apply"
  /// (docs/analytics-events.md) stops being true and a confirmed live row reads as a defect.
  void _trackApplied(
    AnalyticsService analytics,
    Wallpaper wallpaper, {
    required ApplyTarget target,
    required bool confirmed,
    bool fallback = false,
  }) {
    analytics.track(
      ArulEvents.wallpaperApplied,
      properties: {
        ..._applyProps(wallpaper, target: target),
        'confirmed': confirmed,
        if (fallback) 'fallback': true,
      },
    );
  }

  /// Fires `wallpaper_apply_failed` — the other half of the apply funnel.
  ///
  /// Without it, `unsupported` vs `applyFailed` vs `manufacturerRestriction` is invisible to every
  /// sink -> a device class that can NEVER apply anything looks like one nobody tried.
  /// GA4-only, off the PostHog allow-list, like every other `*_attempt` / failure diagnostic.
  /// [code] is the native `PlatformException.code`, or `network`/`unknown` off-channel.
  void _trackFailed(
    AnalyticsService analytics,
    Wallpaper wallpaper, {
    required ApplyTarget target,
    required String code,
  }) {
    analytics.track(
      'wallpaper_apply_failed',
      properties: {
        ..._applyProps(wallpaper, target: target),
        'code': code,
      },
    );
  }

  Future<void> _clearPending(SharedPreferences prefs) async {
    await prefs.remove(appliedWallpaperPendingKey);
    await prefs.remove(pendingApplyPageIndexKey);
    await prefs.remove(pendingApplyCategoryKey);
    await prefs.remove(pendingApplyIsLiveKey);
  }

  void reset() => state = const WallpaperApplyIdle();
}

final wallpaperApplyProvider =
    NotifierProvider<WallpaperApplyNotifier, WallpaperApplyState>(
      WallpaperApplyNotifier.new,
    );
