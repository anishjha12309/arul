import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../data/models/wallpaper.dart';
import '../data/feed_video_player.dart';
import '../data/wallpaper_prefetch_service.dart';

/// How long the feed must rest on a page before its player is reassigned and its media opened.
///
/// A fast fling snaps PageView through intermediate pages, firing onPageChanged for each.
/// Without this gate every passing page re-`open()`s a player, churning faster than it settles.
/// While settling, nothing new is mounted and no player is reassigned.
const Duration _settleDebounce = Duration(milliseconds: 160);

/// A live-video slot for one index — the texture id, the video's intrinsic size, a first-frame flag.
///
/// [ready] is a [ValueListenable], not a bool -> each card subscribes only to ITS OWN flip.
/// A readiness tick then rebuilds that one card, never the whole feed.
class LiveVideoSlot {
  const LiveVideoSlot({
    required this.index,
    required this.playerId,
    required this.textureId,
    required this.videoSize,
    required this.ready,
  });

  /// Feed index this slot serves.
  final int index;

  /// Stable identity of the pooled player backing this slot.
  ///
  /// The card MUST key its [Texture] by this, NEVER by [index].
  /// The pool reassigns a physical player across indices -> a card must rebind to the new player.
  /// Keying by [playerId] forces a fresh element; keying by [index] leaves a stale one.
  final int playerId;

  /// The native texture id the card renders. Owned by the reuse pool, and survives reassignment.
  final int textureId;

  /// The video's intrinsic size, for BoxFit.cover — a raw [Texture] does not scale itself.
  /// Null until the native `videoSize` event arrives; the poster alone covers the card until then.
  final ValueListenable<Size?> videoSize;

  /// Per-item first-frame flag the card listens to in isolation.
  final ValueListenable<bool> ready;
}

/// One pooled native player — a [FeedVideoPlayer] handle plus the bookkeeping that drives reveal.
///
/// **Created ONCE and reused across feed indices** — ExoPlayer, [Texture] and surface all survive.
/// Moving to a new index is a [FeedVideoPlayer.open], NEVER a dispose+recreate.
/// Recreating per swipe allocated a fresh Android surface each time.
/// That surface churn — not the decode — caused the settle-frame jank on budget MediaTek SoCs.
/// It also produced the `BLASTBufferQueue ... Already acquired max frames` flood.
/// Each new surface renegotiates the display refresh rate -> reuse makes a swipe a media swap.
class _PooledPlayer {
  _PooledPlayer({required this.handle});

  /// The native player handle; its `playerId` is the identity the UI sees as [LiveVideoSlot.playerId].
  /// A card keys its [Texture] by the physical player, which survives reassignment, not by index.
  final FeedVideoPlayer handle;

  int get id => handle.playerId;

  /// Feed index this player serves, or -1 when idle — created but not yet assigned.
  int servingIndex = -1;

  /// Network URL of the media this player actually OPENED, stamped once `open()` is invoked.
  ///
  /// NEVER at assignment time — a setup that abandons before opening must leave this null.
  /// The next reconcile then re-opens instead of trusting a never-opened player.
  /// An index alone is NOT identity: a category switch swaps the whole list under the pager.
  /// So "serving index 0" can mean a different wallpaper -> reconcile compares this URL.
  String? openedUrl;

  /// Per-item first-frame flag, owned by the native handle; the card holds a reference via the slot.
  /// Reset to false before each `open()`, and true again on the native onRenderedFirstFrame.
  ValueListenable<bool> get ready => handle.firstFrame;

  /// Native video size for BoxFit.cover scaling, owned by the native handle.
  ValueListenable<Size?> get videoSize => handle.videoSize;

  /// Bumped on every reassignment.
  /// A fling can reassign a player twice before the first [_setupAndOpen] finishes its disk lookup.
  /// The stale setup checks this token and abandons -> it cannot open onto a reassigned player.
  int openToken = 0;

  /// Decoder-error retries consumed by the CURRENT open, reset on every reassignment.
  /// The first error gets a plain retry; a SECOND on the same open proves codec starvation.
  int retriesThisOpen = 0;

  /// True once this open's silent software-decoder fallback was acted on, reset per reassignment.
  /// So one open demotes the session budget at most once, even if the native side re-reports.
  bool swFallbackHandled = false;

  /// Safety-net timer — reveals the card even if the native `firstFrame` event never arrives.
  /// So a driver or stream quirk cannot strand a card on a poster. Reset per open.
  Timer? _revealTimer;

  Future<void> dispose() async {
    _revealTimer?.cancel();
    // Releases the native ExoPlayer and its SurfaceProducer — the decoder AND the surface.
    // Only ever called from releaseDecoders or dispose — NEVER per scroll.
    await handle.dispose();
  }
}

/// Drives the reel's live previews over a small FIXED REUSE POOL of native Media3 players.
/// Backed by a separate disk byte-prefetcher.
///
/// **Two decoupled windows** — the key to fast previews on budget SoCs:
///   - **Data window** ([WallpaperPrefetchService]) — downloads upcoming MP4 BYTES to disk.
///     No player and no decoder, just network and disk -> many items ahead, cheaply;
///   - **Decoder window** ([_keepBehind] behind, [_preloadAhead] ahead) — the only place real
///     ExoPlayers, and so hardware decoders and surfaces, exist.
///
/// The decoder window is previous + current + next, so a back-swipe lands pre-decoded too.
/// A held decoder is scarce on budget MediaTek SoCs, and the wallpaper service claims one for good.
/// So 3 is the HARD CEILING here.
/// **Reuse, not recreate** — the pool holds at most [_poolSize] players for the whole session.
/// A page change reassigns via `open()`, never disposing the outgoing player.
/// Recreating per swipe allocated a fresh surface each time, and that churn caused the jank.
/// Players are disposed only on [releaseDecoders] and [dispose] — never per scroll.
/// Players open the PREFETCHED LOCAL FILE when present, falling back to the CDN URL.
/// Only the CURRENT index plays; neighbours open with `playWhenReady: false` and paint one frame.
/// A live item outside the window has no player and shows its poster alone.
/// On background every player is disposed -> the OEM chooser or our own service can claim a decoder.
class VideoPreloadController extends ChangeNotifier
    with WidgetsBindingObserver {
  VideoPreloadController({
    required this.cdnBaseUrl,
    required WallpaperPrefetchService prefetch,
    FeedVideoPlayerPool? pool,
  }) : _prefetch = prefetch, // ignore: prefer_initializing_formals
       _pool = pool ?? FeedVideoPlayerPool() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// CDN base used to build the public stream URL for live previews.
  final String cdnBaseUrl;

  /// Downloads upcoming live MP4 bytes to disk ahead of the decoder window. Owns NO decoders.
  ///
  /// **Injected, app-scoped, NOT owned by this controller** — it is the shared
  /// [wallpaperPrefetchServiceProvider] instance so the root warm prefetch
  /// (started during splash) and this controller's per-page prefetch share one
  /// in-flight queue. Therefore [dispose] must NOT dispose it (the provider
  /// does); doing so would kill prefetching for the next controller instance.
  final WallpaperPrefetchService _prefetch;

  /// The native player pool (channel wrapper). Owned by this controller: it is
  /// created per controller instance and torn down in [dispose].
  final FeedVideoPlayerPool _pool;

  // Decoder-window radius around the current index — live items inside it get a real player.
  // keepBehind = 1 keeps the PREVIOUS player alive -> a back-swipe lands pre-decoded, like forward.
  // Cost: at most previous + current + next = 3 concurrent decoders, one over the budget-SoC 2.
  // Affordable only because players open from the DISK prefetch, not a cold stream.
  // And because only the current index plays, while the pool reuses players across indices.
  // 3 is the CEILING on the lowest-end target SoC — the wallpaper service claims one permanently.
  // So re-verify deep-scroll stability on a real budget device.
  static const _keepBehind = 1;
  static const _preloadAhead = 1;

  /// Fixed maximum pooled players — the full window width, previous + current + next.
  /// The pool NEVER grows past this; a page change reassigns rather than allocates.
  static const _poolSize = _keepBehind + 1 + _preloadAhead;

  /// **Adaptive decoder budget** — how many concurrent decoders the feed may hold.
  ///
  /// Session-sticky: it survives a feed remount, and resets on app restart for a fresh try.
  /// Starts at the full window -> a capable device keeps the exact previous+current+next pipeline.
  /// Budget SoCs cap hardware decoder instances, commonly at 2 -> the 3rd `prepare()` fails init.
  /// That card then stayed permanently on its poster.
  /// Capability APIs lie in BOTH directions -> **attempt-and-degrade**, never trust them.
  /// A REPEATED decoder-class error on one open demotes the budget by one ([_demoteBudget]).
  /// The previous-index slot drops first; worst case is current-only.
  /// Devices that never error never demote.
  static int _decoderBudget = _poolSize;

  /// Effective window radii — budget 3 is previous+current+next, 2 is current+next, 1 current only.
  int get _effKeepBehind => _decoderBudget >= 3 ? _keepBehind : 0;
  int get _effPreloadAhead => _decoderBudget >= 2 ? _preloadAhead : 0;

  /// Delay before re-`open()`ing errored media — long enough for the codec it needs to be released.
  /// Short enough to beat the user's next glance.
  static const _errorRetryDelay = Duration(milliseconds: 250);

  /// Decoder-error retries allowed per open before giving up — the card then keeps its poster.
  /// The next reconcile, a swipe or a refresh, tries again fresh.
  static const _maxRetriesPerOpen = 2;

  /// Upper bound on how long a card holds its poster waiting for the first frame.
  /// The native onRenderedFirstFrame flip is the PRIMARY path and normally fires well before this.
  /// This exists purely so a quirk that emits no first frame cannot strand the card.
  static const _revealTimeout = Duration(milliseconds: 300);

  int _currentIndex = 0;
  List<Wallpaper> _wallpapers = const [];
  bool _disposed = false;
  bool _appPaused = false;

  /// True between a page change and [_settleDebounce] firing — no player is reassigned while set.
  /// So a fast fling triggers no `open()` churn; reconcile runs once the feed rests.
  bool _settling = false;
  Timer? _settleTimer;

  /// The fixed reuse pool — grows lazily to [_poolSize], then is reused for the session.
  /// Cleared only by [releaseDecoders] and [dispose].
  /// A player with `servingIndex == -1` is idle and available for reassignment.
  final List<_PooledPlayer> _pool_ = [];

  /// Native `create()`s in flight -> concurrent [_assignPlayer] calls cannot over-create.
  int _creating = 0;

  /// The slot serving [index] — null when the item is static, out of window, or unassigned.
  ///
  /// Deliberately does NOT withhold the slot while [_settling].
  /// The settle gate debounces REASSIGNMENT only; it must not unmount an already-serving player.
  /// Dropping every slot on page-change tore down the just-landed card's texture and remounted it.
  /// Its first frame was already decoded, so the remount flashed dark `fill` — the black blink.
  /// Keeping an in-window served slot mounted -> a swipe onto a neighbour shows its frame continuously.
  /// Indices with no serving player still return null, so a fast fling is unaffected.
  LiveVideoSlot? slotForIndex(int index) {
    if (index < 0 || index >= _wallpapers.length) return null;
    if (_wallpapers[index].kind != WallpaperKind.live) return null;
    if (!_inWindow(index)) return null;
    final pooled = _playerServing(index);
    if (pooled == null) return null; // not assigned yet (reconcile is async)
    return LiveVideoSlot(
      index: index,
      playerId: pooled.id,
      textureId: pooled.handle.textureId,
      videoSize: pooled.videoSize,
      ready: pooled.ready,
    );
  }

  /// Call when the viewer opens, or the list changes.
  ///
  /// [initialIndex] MUST be the page the viewer is actually opening on.
  /// Without it the reconcile runs against the PREVIOUS `_currentIndex`.
  /// The pool then opens and prefetches the wrong clips before the debounce re-targets ~160ms later.
  void setWallpapers(List<Wallpaper> wallpapers, {int? initialIndex}) {
    _wallpapers = wallpapers;
    if (initialIndex != null &&
        initialIndex >= 0 &&
        initialIndex < wallpapers.length) {
      _currentIndex = initialIndex;
    }
    _reconcile();
  }

  /// Detach from the surface that was showing video — called ONLY on the way out.
  ///
  /// The controller is app-scoped, so its list and index outlive the screen, deliberately.
  /// That is what survives the Android 12+ Activity recreate a wallpaper apply triggers.
  /// But a stale non-empty list then sits here, and `resumed` reconciles unconditionally.
  /// Backgrounding off-feed and returning would play a clip nobody can see, on real decoders.
  /// CLEARING the list is what makes `resumed` a no-op — `_reconcile` early-returns on empty.
  void detach() {
    _wallpapers = const [];
    _currentIndex = 0;
    unawaited(releaseDecoders());
  }

  /// Splash-gate hook — warm ONLY the first item's decoder, so a gate can hold until it paints.
  ///
  /// Limited to a SINGLE decoder, not the usual window -> safe while the sign-in video holds one.
  /// That keeps it inside the budget-SoC concurrent-decoder limit.
  /// The normal current±1 window takes over once the feed calls [setWallpapers].
  /// Returns the first item's first-frame listenable when a LIVE item is being warmed.
  /// Null when there is nothing to decode — empty feed, backgrounded, or a static first item.
  ValueListenable<bool>? prewarmFirst(List<Wallpaper> wallpapers) {
    if (_disposed || wallpapers.isEmpty || _appPaused) return null;
    _wallpapers = wallpapers;
    _currentIndex = 0;
    if (wallpapers.first.kind != WallpaperKind.live) return null;
    // Pull the look-ahead bytes to disk -> this player, and the next, open from a local file.
    _prefetch.prefetchAround(wallpapers, 0);
    final existing = _playerServing(0);
    if (existing != null) return existing.ready;
    // Native create() is async -> return a PROXY notifier the caller can subscribe to at once.
    // It resolves the moment the player is created and opened.
    return _assignPlayerReady(0, playWhenReady: true);
  }

  /// Disposes every pooled player immediately. The pool re-creates lazily as cards go active again.
  ///
  /// The future completes once every native player finished its platform `dispose`.
  /// The native handler releases codec and surface synchronously before replying.
  /// The apply flow AWAITS this before the native call -> the OS finds the decoders free.
  /// Fire-and-forget call sites — lifecycle pause, screen dispose — just ignore the future.
  Future<void> releaseDecoders() async {
    if (_disposed) return;
    // Cancel any pending settle -> the timer cannot reassign a player right after a release.
    _settleTimer?.cancel();
    _settling = false;
    // Invalidate any player creation still in flight.
    // A `create()` awaiting when release ran lands AFTERWARDS, into the pool we just emptied.
    // It then holds a decoder the apply flow promised the OS was free, or plays with nobody watching.
    // `_appPaused` alone catches backgrounding but NOT a FOREGROUND release, now the common case.
    _releaseEpoch++;
    final players = _pool_.toList();
    _pool_.clear();
    final disposals = [for (final p in players) p.dispose()];
    notifyListeners(); // cards re-read slotForIndex → poster only
    await Future.wait(disposals);
  }

  /// Bumped by every [releaseDecoders].
  /// A creation snapshots it before awaiting and discards itself if the value moved.
  int _releaseEpoch = 0;

  /// Rebuilds the player window after an apply that kept the app FOREGROUND.
  ///
  /// The resumed-lifecycle reconcile never fires without a chooser or a backgrounding.
  /// Without this, every live card stranded on a poster that never revealed.
  /// A no-op while backgrounded — the resume path owns that case — and idempotent when serving.
  void reclaimDecoders() {
    if (_disposed || _appPaused) return;
    _reconcile();
  }

  /// Call whenever [PageView.onPageChanged] fires.
  ///
  /// The index is recorded at once, but REASSIGNMENT is debounced by [_settleDebounce].
  /// A fast fling fires this per intermediate page, and re-`open()`ing each would churn decoders.
  /// So it enters "settling" — reassign nothing, pause what played — and rebuilds once at rest.
  Future<void> onPageChanged(int index) async {
    if (_disposed) return;
    _currentIndex = index;

    // Enter settling: pause every player so nothing plays during the scroll, then rebuild.
    // Already-serving in-window cards KEEP their slot — their Texture stays mounted, paused.
    // Not-yet-served cards still read null and show their poster.
    final wasSettling = _settling;
    _settling = true;
    if (!_appPaused) _pauseAll();
    if (!wasSettling) notifyListeners(); // re-read slotForIndex

    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDebounce, () {
      if (_disposed) return;
      _settling = false;
      _reconcile();
    });
  }

  bool _inWindow(int index) {
    final start = max(0, _currentIndex - _effKeepBehind);
    final end = min(_wallpapers.length - 1, _currentIndex + _effPreloadAhead);
    return index >= start && index <= end;
  }

  /// The pooled player currently serving [index], or null if none is.
  _PooledPlayer? _playerServing(int index) {
    for (final p in _pool_) {
      if (p.servingIndex == index) return p;
    }
    return null;
  }

  /// Recomputes player→index assignments to match the window, WITHOUT disposing players.
  ///
  /// A player already serving an in-window live index stays put, surface and decoded frame intact.
  /// A player on a stale index is freed and reassigned via `open()` to an index that lacks one.
  /// Play state is set so ONLY the current index plays actively.
  /// New players are created only until the pool reaches [_poolSize].
  /// Notifies listeners -> the feed's itemBuilder re-reads [slotForIndex].
  void _reconcile() {
    if (_disposed || _wallpapers.isEmpty) return;

    // Target set: the LIVE indices inside the current window that deserve a player.
    // Previous + current + next at the full budget, shrunk on codec-starved SoCs.
    final start = max(0, _currentIndex - _effKeepBehind);
    final end = min(_wallpapers.length - 1, _currentIndex + _effPreloadAhead);
    final wanted = <int>[
      for (var i = start; i <= end; i++)
        if (_wallpapers[i].kind == WallpaperKind.live) i,
    ];

    // 1. Free any player whose index left the window, is no longer live, or whose MEDIA moved.
    //    A category switch replaces the list under the pager -> index 0 can be a different clip.
    //    Without the URL check the old category's video kept playing over the new category's card.
    //    Freeing is mark-idle plus pause — the player and its surface are KEPT for reassignment.
    for (final p in _pool_) {
      final idx = p.servingIndex;
      final stillWanted =
          idx >= 0 &&
          idx < _wallpapers.length &&
          _wallpapers[idx].kind == WallpaperKind.live &&
          wanted.contains(idx) &&
          p.openedUrl == _prefetch.urlFor(_wallpapers[idx]);
      if (!stillWanted && idx != -1) {
        p.servingIndex = -1;
        unawaited(p.handle.pause());
      }
    }

    if (_appPaused) {
      notifyListeners();
      return;
    }

    // Drive the DATA window — pull upcoming live MP4s to disk, no decoders.
    // So the players opened here, and the next promoted on swipe, read a local file.
    _prefetch.prefetchAround(_wallpapers, _currentIndex);

    // 2. Assign a player to every wanted index without one, reusing an idle player where possible.
    //    A new one is created only while the pool is below _poolSize.
    //    Then set play state: the current index plays, neighbours stay paused on their first frame.
    for (final i in wanted) {
      final existing = _playerServing(i);
      if (existing == null) {
        _assignPlayer(i, playWhenReady: i == _currentIndex);
      } else if (i == _currentIndex) {
        unawaited(existing.handle.play());
      } else {
        unawaited(existing.handle.pause());
      }
    }

    // Any player STILL idle was wanted by no index this pass — the window shrank, or live thinned.
    // A PAUSED player keeps its codec; stop() releases it, and the surface survives for reuse.
    // So an idle slot cannot starve a wanted one on codec-capped SoCs.
    // Under the full budget every freed player is reassigned above -> a no-op on healthy devices.
    // Reused players take servingIndex synchronously, and a pending create() is not in the pool yet.
    for (final p in _pool_) {
      if (p.servingIndex == -1) {
        p.openToken++; // abandon any in-flight setup/reveal for the old media
        unawaited(p.handle.stop());
      }
    }

    notifyListeners();
  }

  /// Assigns a pooled player to [index] and opens its media, returning its first-frame listenable.
  /// Null when none is available or the app is paused. See [_assignPlayer].
  ValueListenable<bool>? _assignPlayerReady(
    int index, {
    required bool playWhenReady,
  }) {
    final existing = _playerServing(index);
    if (existing != null) return existing.ready;
    // Kick the async assignment and expose a proxy that mirrors the player's first frame.
    final proxy = _FirstFrameProxy();
    unawaited(() async {
      final pooled = await _assignPlayerAsync(
        index,
        playWhenReady: playWhenReady,
      );
      if (pooled == null) {
        proxy.detach();
        return;
      }
      proxy.bind(pooled.ready);
    }());
    return proxy;
  }

  /// Fire-and-forget assignment used from [_reconcile].
  void _assignPlayer(int index, {required bool playWhenReady}) {
    unawaited(_assignPlayerAsync(index, playWhenReady: playWhenReady));
  }

  /// Assigns a pooled player to [index] and opens its media, REUSING an idle player when one exists.
  /// A brand-new native player is created only while the pool is under [_poolSize].
  /// Null when none is available or the app is paused.
  ///
  /// The reuse hot path: an idle player keeps its ExoPlayer and surface, and just re-opens media.
  /// Only the first [_poolSize] assignments of a session allocate a native surface.
  Future<_PooledPlayer?> _assignPlayerAsync(
    int index, {
    required bool playWhenReady,
  }) async {
    if (_appPaused || _disposed) return null;

    // Prefer an idle, already-created player -> reuse its surface.
    _PooledPlayer? pooled;
    for (final p in _pool_) {
      if (p.servingIndex == -1) {
        pooled = p;
        break;
      }
    }

    // No idle player and room to grow -> create one; a surface is a one-time cost per pool slot.
    // _creating guards a fling from over-creating past the cap while a create() is in flight.
    // The cap is the LOWER of the pool size and the decoder budget — a demoted budget never uses more.
    if (pooled == null) {
      if (_pool_.length + _creating >= min(_poolSize, _decoderBudget)) {
        return null;
      }
      _creating++;
      // Snapshot the release epoch BEFORE awaiting -> a release mid-flight becomes detectable.
      final epoch = _releaseEpoch;
      FeedVideoPlayer? handle;
      try {
        handle = await _pool.create();
      } finally {
        _creating--;
      }
      // The pool may have been released, or the app paused, while create() awaited.
      // Drop the fresh player rather than add it to a pool that was just emptied.
      // The EPOCH check covers a FOREGROUND release; `_appPaused` alone catches only backgrounding.
      // Without it a late-landing player holds a decoder the apply flow promised the OS was free.
      if (handle == null || _disposed || _appPaused || _releaseEpoch != epoch) {
        unawaited(handle?.dispose());
        return null;
      }
      pooled = _PooledPlayer(handle: handle);
      // Wire native playback errors into the retry and budget adaptation — the handle filters staleness.
      // The handle is stable for the pooled player's whole life -> wire once, here.
      final errPooled = pooled;
      handle.onError = (codeName) => _onPlayerError(errPooled, codeName);
      // A silent software-decoder fallback fires NO error -> the other contention signal, wired alike.
      handle.onDecoder = (name, isSoftware) =>
          _onDecoderReported(errPooled, name, isSoftware);
      _pool_.add(pooled);
    }

    pooled.servingIndex = index;
    // A reused player's texture still holds the PRIOR clip's last frame, flag still true.
    // Without this the new card renders the OLD wallpaper at full opacity until the lookup resolves.
    // So hide it NOW, synchronously, before the notify and long before open() would reset it.
    pooled.handle.resetForReassign();
    // Do NOT stamp openedUrl here — it is recorded only once open() is actually invoked.
    // A setup that abandons before opening then leaves it null and the next reconcile re-opens.
    // Stamping early made reconcile treat a never-opened player as served: the poster-until-Apply wedge.
    pooled.openedUrl = null;
    // New media -> reset the first-frame flag; onRenderedFirstFrame flips it true when it paints.
    final token = ++pooled.openToken;
    pooled.retriesThisOpen = 0;
    pooled.swFallbackHandled = false;

    // From an EMPTY pool, the async create() lands AFTER _reconcile's own notifyListeners.
    // The feed still holds a null slot, and with no later notify the card keeps its poster forever.
    // The video decodes invisibly until any swipe re-notifies -> notify NOW that the slot resolves.
    // A harmless duplicate on the reused-player path.
    notifyListeners();

    // Safety net -> reveal even if the native first-frame event never arrives within _revealTimeout.
    _armReveal(pooled, index, token);

    // Cold start: the data window stays narrow until the card the user is looking at has painted.
    _armPrefetchWiden(pooled, index);

    await _setupAndOpen(pooled, index, token, playWhenReady: playWhenReady);
    return pooled;
  }

  /// (Re)arms the reveal-timeout safety net for [pooled]'s current open.
  ///
  /// Guarded by [token] and serving index -> a since-reassigned player never reveals.
  /// The handle also refuses to force-reveal an ERRORED open, whose texture is black.
  /// The timer reveals ONLY when native confirms it actually PAINTED this open's first frame.
  /// A blind force-reveal on a REUSED player flashed the previous clip's frozen frame.
  /// That repeated one wallpaper over card after card -> keeping the poster is the right fallback.
  /// Genuine failures heal via the error retry and the post-open `openedUrl` stamping.
  void _armReveal(_PooledPlayer pooled, int index, int token) {
    pooled._revealTimer?.cancel();
    pooled._revealTimer = Timer(_revealTimeout, () async {
      if (_disposed ||
          pooled.openToken != token ||
          pooled.servingIndex != index) {
        return;
      }
      final painted = await pooled.handle.hasPaintedCurrentOpen();
      // Re-check after the async query — the player may have been reassigned while we asked native.
      if (_disposed ||
          pooled.openToken != token ||
          pooled.servingIndex != index) {
        return;
      }
      if (painted) pooled.handle.forceFirstFrame();
    });
  }

  /// One-shot — when the CURRENT card paints, restore the prefetch service's full depth and re-issue.
  ///
  /// On a cold sign-in the look-ahead is ~40 MB nothing has cached, competing with the clip on screen.
  /// Waiting for this signal costs nothing: by then the user watches video and the pipe is free.
  /// Armed only while staging is live, and only for the current index.
  /// The service's own fallback timer covers a static first card, or a first-frame event that never lands.
  void _armPrefetchWiden(_PooledPlayer pooled, int index) {
    if (_prefetch.windowWidened || index != _currentIndex) return;
    final painted = pooled.handle.firstFrame;
    void onPainted() {
      if (!painted.value) return;
      painted.removeListener(onPainted);
      if (_disposed || _prefetch.windowWidened) return;
      _prefetch.widenWindow();
      _prefetch.prefetchAround(_wallpapers, _currentIndex);
    }

    painted.addListener(onPainted);
    onPainted(); // may already be true on a reused, already-painted player
  }

  Future<void> _setupAndOpen(
    _PooledPlayer pooled,
    int index,
    int token, {
    required bool playWhenReady,
  }) async {
    // Guard — the list may have shrunk between assignment and here.
    if (index < 0 || index >= _wallpapers.length) return;
    // Capture the network URL now — it is both the disk-cache key and the streaming fallback.
    final url = _prefetch.urlFor(_wallpapers[index]);

    // Prefer the prefetched local FILE -> instant first frame, no network round trip.
    // Falls back to the CDN URL when the data window has not reached this item, streaming +faststart.
    final localPath = await _prefetch.cachedPathOrNull(url);

    // A fling may have reassigned this player, or released the pool, while we awaited the lookup.
    // A moved openToken means a newer open() owns it -> abandon, or we stomp its media.
    if (_disposed ||
        pooled.openToken != token ||
        pooled.servingIndex != index ||
        _appPaused) {
      return;
    }

    // The guard above proved this assignment current -> we are committed, so record identity NOW.
    // Stamping at ASSIGNMENT time wedged the card: an abandon left openedUrl matching the item.
    // _reconcile then treated a never-opened player as served — poster only until an Apply.
    pooled.openedUrl = url;

    // playWhenReady false still decodes and PAINTS a first frame -> a paused neighbour is ready.
    // The current index passes true. Re-opening a reused player swaps media without the surface.
    // Looping, so the short preview repeats seamlessly.
    await pooled.handle.open(
      localPath ?? url,
      playWhenReady: playWhenReady,
      looping: true,
    );
  }

  /// The decoder-contention error class — init, decode, capability and reclaim all share one prefix.
  /// Matched by NAME, so nothing depends on Media3's numeric values.
  /// Network and source errors are excluded — a smaller window would not help them.
  static bool _isDecoderError(String codeName) =>
      codeName.startsWith('ERROR_CODE_DECODER') ||
      codeName.startsWith('ERROR_CODE_DECODING');

  /// Native playback error on the media [pooled] is serving — the budget-SoC self-tuning path.
  ///
  ///   1. first decoder-class error on an open → a plain retry after [_errorRetryDelay];
  ///      if the failing index is CURRENT, the farthest neighbour is stopped first;
  ///   2. second error on the SAME open → the SoC genuinely cannot hold this many decoders,
  ///      so demote [_decoderBudget], shrinking the window previous-slot first, and retry once more;
  ///   3. [_maxRetriesPerOpen] exhausted → give up quietly; the card keeps its poster, never black.
  ///
  /// Capable devices never enter this path, and the next reconcile starts fresh.
  void _onPlayerError(_PooledPlayer pooled, String codeName) {
    if (_disposed || _appPaused) return;
    final index = pooled.servingIndex;
    if (index < 0) return;
    final token = pooled.openToken;

    if (pooled.retriesThisOpen >= _maxRetriesPerOpen) {
      debugPrint(
        'FeedVideo: giving up on index $index after $codeName '
        '(budget $_decoderBudget)',
      );
      return;
    }
    pooled.retriesThisOpen++;

    if (!_isDecoderError(codeName)) {
      // An open or source failure means the open may simply not have taken.
      // Shrinking the decoder window would not help -> do NOT demote.
      // Null the opened identity and re-open once, rather than wedge the card on its poster.
      // Nulling openedUrl also lets an interleaving reconcile re-open, whichever fires first.
      pooled.openedUrl = null;
      debugPrint(
        'FeedVideo: $codeName on index $index — re-open '
        '${pooled.retriesThisOpen}/$_maxRetriesPerOpen',
      );
      _scheduleReopen(pooled, index, token);
      return;
    }

    // A repeat failure on the SAME open is real codec starvation, not a blip.
    if (pooled.retriesThisOpen >= 2) {
      _demoteBudget('$codeName at index $index');
    }

    // The visible card must always win a decoder.
    if (index == _currentIndex) _stopFarthestFrom(index);

    debugPrint(
      'FeedVideo: $codeName on index $index — '
      'retry ${pooled.retriesThisOpen}/$_maxRetriesPerOpen '
      '(budget $_decoderBudget)',
    );

    _scheduleReopen(pooled, index, token);
  }

  /// Schedules ONE delayed re-open of [pooled]'s current media after [_errorRetryDelay].
  /// Guarded, so a reassigned, released or out-of-window player is left alone.
  /// Shared by the decoder-error retry, the software-fallback re-open and the open-failure retry.
  void _scheduleReopen(_PooledPlayer pooled, int index, int token) {
    Timer(_errorRetryDelay, () {
      if (_disposed ||
          _appPaused ||
          pooled.openToken != token ||
          pooled.servingIndex != index ||
          !_inWindow(index)) {
        return; // reassigned / released / demoted out of the window meanwhile
      }
      _armReveal(pooled, index, token);
      unawaited(
        _setupAndOpen(
          pooled,
          index,
          token,
          playWhenReady: index == _currentIndex && !_settling,
        ),
      );
    });
  }

  /// Frees the codec of the player serving the index FARTHEST from [index], never [index] itself.
  /// stop() releases the decoder but keeps the player and surface for reassignment.
  /// Its card returns to its poster until a later reconcile — the price of the current card rendering.
  void _stopFarthestFrom(int index) {
    _PooledPlayer? victim;
    var best = 0;
    for (final p in _pool_) {
      if (p.servingIndex < 0 || p.servingIndex == index) continue;
      final d = (p.servingIndex - index).abs();
      if (d > best) {
        best = d;
        victim = p;
      }
    }
    if (victim == null) return;
    debugPrint(
      'FeedVideo: freeing decoder of neighbour index ${victim.servingIndex} '
      'for index $index',
    );
    victim.servingIndex = -1;
    victim.openToken++; // abandon its in-flight setup/reveal
    unawaited(victim.handle.stop());
    notifyListeners();
  }

  /// Shrinks the session decoder budget by one, floor 1 — the current card.
  /// Reconciles, so now-out-of-window players are freed and stopped immediately.
  /// Returns whether the budget actually CHANGED, false at the floor, so callers skip a no-op.
  bool _demoteBudget(String reason) {
    if (_decoderBudget <= 1) return false;
    _decoderBudget--;
    debugPrint(
      'FeedVideo: decoder budget demoted to $_decoderBudget ($reason)',
    );
    _reconcile();
    return true;
  }

  /// Native decoder report for [pooled]'s current open (see [FeedVideoPlayer.onDecoder]).
  ///
  /// A SOFTWARE decoder means ExoPlayer quietly downgraded — the SoC is out of hardware sessions.
  /// NO [_onPlayerError] ever fires for this.
  /// On an SD695, 3 players against a ~2-session budget pinned slots to `c2.android.avc.decoder`.
  /// That costs battery and thermal, and renders gralloc stride padding as the green edge strip.
  ///   - demote the session budget once per open -> the shrunken window frees a hardware session;
  ///   - sw fallback ALONE never demotes below 2 — it is an occasional lottery loss even when it fits,
  ///     and 128/32-aligned content renders CLEAN on the sw path, so a sw neighbour costs only battery;
  ///   - budget 1 costs preloading: every swipe drops back to the poster. Real ERRORS may still reach 1;
  ///   - if the VISIBLE card landed on software, re-open it after a demote that actually changed
  ///     the budget, so it re-initializes onto the freed hardware decoder now, not on the next swipe.
  ///
  /// A sw-only device settles at the floor, with no re-open loop.
  void _onDecoderReported(_PooledPlayer pooled, String name, bool isSoftware) {
    if (_disposed || _appPaused || !isSoftware) return;
    final index = pooled.servingIndex;
    if (index < 0 || pooled.swFallbackHandled) return;
    pooled.swFallbackHandled = true;

    if (_decoderBudget <= 2) {
      debugPrint(
        'FeedVideo: software decoder $name on index $index — tolerated '
        '(budget $_decoderBudget, sw-fallback floor is 2)',
      );
      return;
    }
    final demoted = _demoteBudget('software decoder $name at index $index');
    if (!demoted || index != _currentIndex) return;

    // Re-open the visible card -> it re-initializes onto the decoder the demote just freed.
    _scheduleReopen(pooled, index, pooled.openToken);
  }

  void _pauseAll() {
    for (final pooled in _pool_) {
      unawaited(pooled.handle.pause());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.inactive:
        _appPaused = true;
        _settleTimer?.cancel();
        _pauseAll();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Off-screen — the OEM live-wallpaper chooser may be over us.
        // Dispose every player so the chooser, or our own service, can claim a decoder.
        _appPaused = true;
        unawaited(releaseDecoders());
      case AppLifecycleState.detached:
        _appPaused = true;
      case AppLifecycleState.resumed:
        _appPaused = false;
        // Clear stale settling state, e.g. backgrounded mid-fling -> the card hands out its slot.
        _settling = false;
        _reconcile();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _settleTimer?.cancel();
    // Do NOT dispose _prefetch — it is the shared app-scoped instance and outlives this controller.
    // A remount then keeps the same disk cache and in-flight queue. The provider disposes it.
    WidgetsBinding.instance.removeObserver(this);
    final players = _pool_.toList();
    _pool_.clear();
    for (final p in players) {
      unawaited(p.dispose());
    }
    unawaited(_pool.dispose());
    super.dispose();
  }
}

/// A proxy `ValueListenable<bool>` a caller can subscribe to synchronously while create() is async.
/// [bind] makes it mirror the real first-frame notifier; [detach] resolves it false if create failed.
class _FirstFrameProxy extends ChangeNotifier implements ValueListenable<bool> {
  bool _value = false;
  ValueListenable<bool>? _source;
  VoidCallback? _listener;

  @override
  bool get value => _value;

  void bind(ValueListenable<bool> source) {
    _source = source;
    void listener() {
      _value = source.value;
      notifyListeners();
    }

    _listener = listener;
    source.addListener(listener);
    // Sync the current value immediately — it may already be true.
    if (source.value != _value) {
      _value = source.value;
      notifyListeners();
    }
  }

  void detach() {
    final s = _source;
    final l = _listener;
    if (s != null && l != null) s.removeListener(l);
    _source = null;
    _listener = null;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}
