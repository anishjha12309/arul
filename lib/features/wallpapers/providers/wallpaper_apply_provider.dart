import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/error/app_exception.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/providers/auth_providers.dart';
import '../../../data/models/wallpaper.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/wallpaper_apply_service.dart';
import 'wallpaper_prefetch_provider.dart';

// ─── Pending-apply flags ──────────────────────────────────────────────────────
//
// Written to SharedPreferences BEFORE the native apply call. On Android 12+ a
// wallpaper change makes the OS re-extract Material You colours and can recreate
// our Activity (flutter#133722); the live-wallpaper chooser also opens over us.
// These flags let the feed jump straight back to the page the user was on,
// instead of showing a full-screen spinner — a flicker instead of a visible cold
// restart. Set for BOTH static and live.

const appliedWallpaperPendingKey = 'applied_wallpaper_pending';
const pendingApplyPageIndexKey = 'pending_apply_page_index';
const pendingApplyCategoryKey = 'pending_apply_category';

/// True when the pending apply was LIVE. Position is restored for both, but only
/// static shows an "applied" confirmation: we cannot observe the live chooser's
/// outcome, so claiming success there would be a lie.
const pendingApplyIsLiveKey = 'pending_apply_is_live';

// ─── State ────────────────────────────────────────────────────────────────────

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

  /// 0.0–1.0 while downloading; null for the other stages (which are indefinite,
  /// so the UI must show an indeterminate indicator, not a 0% bar).
  final double? progress;
}

final class WallpaperApplySuccess extends WallpaperApplyState {
  const WallpaperApplySuccess({required this.isLive});
  final bool isLive;
}

final class WallpaperApplyError extends WallpaperApplyState {
  const WallpaperApplyError({
    required this.message,
    this.isNetwork = false,
    this.premiumRequired = false,
  });

  /// DIAGNOSTIC ONLY -- never show this to a user. It can be a raw
  /// `FileSystemException: ...`, and it is English regardless of locale. The UI
  /// maps [isNetwork] to a localized line; this is here for logs and, later,
  /// crash reporting.
  final String message;

  /// Offline, not broken. The UI says so, and offers retry.
  final bool isNetwork;

  /// The server refused this apply because the subscription is no longer live.
  /// The screen routes to the paywall instead of showing a generic failure —
  /// otherwise a lapsed subscriber hits an English dead end with no way to
  /// resubscribe from where they are.
  final bool premiumRequired;
}

// ─── Shared cache filename ────────────────────────────────────────────────────

/// The ONE temp-file name apply and share both use for a given wallpaper.
///
/// They must agree. Share used to prefix the file `arul-…` for a friendly name in
/// the recipient's chat — which meant applying and then sharing the same wallpaper
/// downloaded the identical bytes TWICE. The recipient-facing name is a share-sheet
/// concern and is set there via `fileNameOverrides`; the file on disk is a cache
/// key and belongs to whoever fetched it first.
String applyCacheFilename(Wallpaper w) => w.key.split('/').last;

// ─── Service provider ─────────────────────────────────────────────────────────

final wallpaperApplyServiceProvider = Provider<WallpaperApplyService>(
  (ref) => CdnWallpaperApplyService(apiClient: ref.watch(apiClientProvider)),
);

// ─── Notifier ─────────────────────────────────────────────────────────────────

class WallpaperApplyNotifier extends Notifier<WallpaperApplyState> {
  @override
  WallpaperApplyState build() => const WallpaperApplyIdle();

  /// Runs the whole apply flow. [releaseVideoDecoders] is awaited immediately
  /// before the native call so the feed's ExoPlayers give up the hardware codecs
  /// the wallpaper engine (or the OS chooser) is about to need — on a budget SoC
  /// there are only a handful, and not doing this is what makes an applied live
  /// wallpaper fall back to software decode and stutter.
  Future<void> apply(
    Wallpaper wallpaper, {
    required ApplyTarget target,
    int? feedPageIndex,
    String? category,
    Future<void> Function()? releaseVideoDecoders,
  }) async {
    // Re-entrancy guard: a double-tap on Apply must not start two downloads and
    // two native calls racing to write the same temp file.
    if (state is WallpaperApplyLoading) return;

    final service = ref.read(wallpaperApplyServiceProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final isLive = wallpaper.kind == WallpaperKind.live;

    // Claim the flow BEFORE the first await. The re-entrancy check above runs
    // ahead of `getTemporaryDirectory()` and `exists()` — two awaits — so a
    // double-tap inside those few milliseconds previously started two downloads
    // racing to write the same file.
    state = const WallpaperApplyLoading(stage: WallpaperApplyStage.preparing);

    try {
      final filename = applyCacheFilename(wallpaper);
      final tmpDir = await getTemporaryDirectory();
      final cachedFile = File('${tmpDir.path}/$filename');

      File? file;

      if (await cachedFile.exists() && await cachedFile.length() > 0) {
        // Already fetched by a previous apply or share of this wallpaper — e.g.
        // the user dismissed the OEM chooser last time.
        file = cachedFile;
      } else {
        // The live clip the user is looking at is almost always ALREADY on disk:
        // the feed prefetcher pulled it so the player could open a local file
        // instead of streaming. Apply and prefetch now resolve the SAME public CDN
        // URL, so those bytes are reusable — copying them locally beats spending
        // another 2-15 MB of the user's mobile data re-downloading a file we have.
        // (This was impossible in the reference: apply fetched a signed URL, so the
        // two caches could never share a key. The port inherited the miss.)
        final prefetched = await ref
            .read(wallpaperPrefetchServiceProvider)
            .cachedPathOrNull(await service.resolveUrl(wallpaper));
        if (prefetched != null) {
          try {
            file = await File(prefetched).copy(cachedFile.path);
          } catch (_) {
            // Evicted between the lookup and the copy. Fall through and download.
          }
        }
      }

      if (file != null) {
        // The bytes are already on disk (a previous apply/share, or the feed
        // prefetcher pulled them for playback), so the DOWNLOAD is skipped —
        // but the gate is not.
        //
        // `/media/signed-url` is the only authoritative entitlement check
        // (CLAUDE.md §5); the client-side gate ahead of it is UX. These local
        // branches used to skip the round-trip entirely, which meant a user
        // whose subscription had lapsed, been cancelled or been refunded could
        // keep re-applying anything already on disk, indefinitely — the cache
        // silently became a permanent licence.
        try {
          await service.downloadUrl(wallpaper);
        } on WallpaperApplyException catch (e) {
          // A real 403 is the gate doing its job — surface it so the screen
          // routes to the paywall. Any other API failure on bytes we already
          // hold is not worth blocking a paying user over.
          if (e.premiumRequired) rethrow;
        } catch (e) {
          if (!isNetworkError(e)) rethrow;
          // Offline, with the file already on disk from a previously-passing
          // gate. Allow it: stranding a paying user in a dead zone is a worse
          // outcome than the narrow bypass this leaves open, and the bypass
          // dies with the temp directory.
        }
      }

      if (file == null) {
        // The GATED download URL: Worker signed-url (live entitlement check)
        // when the backend exists, public CDN before then.
        final url = await service.downloadUrl(wallpaper);

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

      // Denominator of the apply funnel. The download and the authoritative
      // entitlement gate are both behind us here, so anything that fails past
      // this line is the native call or the OS — which is exactly the ratio
      // `wallpaper_applied / wallpaper_apply_attempt` measures. GA4-only (not on
      // the PostHog allow-list): attempts are volume, and volume is the thing
      // GA4 takes at 100% for free.
      analytics.track(
        'wallpaper_apply_attempt',
        properties: _applyProps(wallpaper, target: target),
      );

      // Persist restore state BEFORE the native call — see the flag docs above.
      if (feedPageIndex != null) {
        await prefs.setInt(pendingApplyPageIndexKey, feedPageIndex);
      }
      if (category != null) {
        await prefs.setString(pendingApplyCategoryKey, category);
      }
      await prefs.setBool(pendingApplyIsLiveKey, isLive);
      await prefs.setBool(appliedWallpaperPendingKey, true);

      if (isLive) {
        // Two live paths, decided natively:
        //  • our service is ALREADY the active wallpaper → the running engine's
        //    video is swapped in place. No chooser, and the outcome IS
        //    observable, so we report real success.
        //  • otherwise the OS live-wallpaper chooser opens as its own activity
        //    and the user makes the final "Set wallpaper" tap. We cannot observe
        //    that, so we finish IDLE — never a false "applied" confirmation.
        final swappedInPlace = await service.isOwnLiveWallpaperActive();

        // Chooser path only: hand our decoders to the chooser's preview engine
        // before it launches. On the in-place path the native side reuses the
        // already-running engine, and releasing would just black-frame the feed.
        if (!swappedInPlace && releaseVideoDecoders != null) {
          await releaseVideoDecoders();
        }
        await service.applyLiveWallpaper(file, target);

        if (swappedInPlace) {
          await _clearPending(prefs);
          _trackApplied(analytics, wallpaper, target: target, confirmed: true);
          state = const WallpaperApplySuccess(isLive: true);
        } else {
          _trackApplied(analytics, wallpaper, target: target, confirmed: false);
          // Flags stay set: if the chooser causes a recreate, the feed restores
          // position; if it doesn't, the feed consumes them on next resume.
          state = const WallpaperApplyIdle();
        }
        return;
      }

      // Static. Awaited decoder release first — the apply can recreate the
      // Activity, and a completed disposal cannot race Flutter teardown.
      if (releaseVideoDecoders != null) await releaseVideoDecoders();
      await service.applyStaticWallpaper(file, target);

      // We got here, so no OS restart happened: clear flags, confirm inline.
      await _clearPending(prefs);
      _trackApplied(analytics, wallpaper, target: target, confirmed: true);
      state = const WallpaperApplySuccess(isLive: false);
    } on WallpaperApplyException catch (e) {
      await _clearPending(prefs);
      if (e.premiumRequired) {
        // Not a defect — the live entitlement check did its job on a lapsed or
        // refunded subscription. Refresh the stale client snapshot that let the
        // user get this far, then let the screen route to the paywall.
        ref.invalidate(entitlementDetailProvider);
      }
      state = WallpaperApplyError(
        message: e.message,
        premiumRequired: e.premiumRequired,
      );
    } catch (e) {
      await _clearPending(prefs);
      // Offline is the common case here (the download), and it is not a bug —
      // the UI must not print "ClientException: Failed host lookup".
      final network = isNetworkError(e);
      state = WallpaperApplyError(message: e.toString(), isNetwork: network);
    }
  }

  /// Shared property block for the apply funnel, so attempt and completion are
  /// joinable on the same keys.
  ///
  /// Arul's property convention is `wallpaper_id` + `category` — category is this
  /// app's browse axis, so "which collections convert" is answerable off these
  /// events alone. (Pakiza has no category axis and carries only `type`. Keep
  /// each app's own convention rather than unifying, or every saved dashboard in
  /// both projects breaks.)
  ///
  /// `type` is spelled the same way `wallpaper_shared` already spells it
  /// (`kind.name` → `image`/`live`) so the two funnels are joinable on it. It is a
  /// rendering hint, never a browse axis (CLAUDE.md §5b) — do not group by it the
  /// way `category` is grouped.
  Map<String, Object?> _applyProps(
    Wallpaper wallpaper, {
    required ApplyTarget target,
  }) => {
    'wallpaper_id': wallpaper.id,
    'category': wallpaper.category,
    'type': wallpaper.kind.name,
    'target': target.name,
  };

  /// Fires `wallpaper_applied` — the primary value moment, and one of the few
  /// events PostHog is billed for.
  ///
  /// [confirmed] exists because Arul has two live paths with different
  /// observability. A static apply and the in-place live swap both return from a
  /// native call that either worked or threw, so success is a fact. When the OS
  /// live-wallpaper chooser takes over, the user makes the final "Set wallpaper"
  /// tap in an activity we cannot see. The event still fires there — suppressing
  /// it would silently under-count the commonest live path and make the funnel
  /// non-comparable with Pakiza, which fires on chooser-open too — but it is
  /// flagged, so filtering `confirmed = true` recovers the strict count. Never
  /// use the unfiltered number to claim a completion rate.
  void _trackApplied(
    AnalyticsService analytics,
    Wallpaper wallpaper, {
    required ApplyTarget target,
    required bool confirmed,
  }) {
    analytics.track(
      'wallpaper_applied',
      properties: {
        ..._applyProps(wallpaper, target: target),
        'confirmed': confirmed,
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
