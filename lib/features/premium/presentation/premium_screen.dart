import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../data/models/app_config_model.dart';
import '../../../data/models/subscription_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../theme/arul_tokens.dart';
import '../../referral/presentation/share_moment_sheet.dart';
import '../../wallpapers/data/feed_video_player.dart';
import '../../settings/presentation/confirm_dialog.dart';
import '../domain/entitlement.dart';
import '../providers/entitlement_provider.dart';
import '../providers/premium_purchase_provider.dart';
import 'member_view.dart';
import '../domain/onboarding_video.dart';
import 'onboarding_video_card.dart';
import 'paywall_view.dart';
import 'resubscribe_view.dart';

/// Monthly price from app_config `prices` (paise) → "₹199". Falls back to the
/// launch price when the remote config hasn't loaded yet.
String _monthlyPrice(Map<String, dynamic>? prices) {
  final monthly = prices?['monthly'];
  if (monthly is Map && monthly['amount'] is num) {
    final rupees = (monthly['amount'] as num) / 100;
    final asInt = rupees.truncateToDouble() == rupees;
    return '₹${asInt ? rupees.toInt() : rupees.toStringAsFixed(2)}';
  }
  return '₹199';
}

/// `14 Jul 2026`. Null in → null out, so callers can hide the row entirely.
String? _formatDate(DateTime? d) {
  if (d == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = d.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// THE premium screen — paywall and plan home in one route.
///
/// It used to be two screens (Settings → "Arul Premium" → a hero with a
/// "Get Premium" button → the actual paywall), which made a free user tap
/// "premium" twice to see a price. Now `/premium` renders whatever the user's
/// REAL subscription state calls for, in one place:
///   • no plan / expired / paused / pending → the paywall itself (perks, plan
///     card, UPI picker, purchase CTA)
///   • trialing / active                   → plan + billing details + Cancel
///   • cancelled, still paid-through       → "auto-renew off" + billing +
///     an INLINE Resubscribe (same purchase flow, no extra screen)
///
/// `source` says which blocked verb (or settings) sent the user here — the one
/// number that tells you which entry point actually sells the product. Tracking
/// happens at the gate (`ensurePremium`), not here.
///
/// This is also the only route that can reach `POST /payments/cancel`.
class PremiumScreen extends ConsumerStatefulWidget {
  const PremiumScreen({super.key, required this.source});

  final String source;

  @override
  ConsumerState<PremiumScreen> createState() => _PremiumScreenState();
}

/// Shared colour resolution for every state this screen can render — resolved
/// once per build so the paywall, the billing card and the picker sheet cannot
/// drift apart on theme.
class _Palette {
  _Palette(bool isDark)
    : bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory,
      textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText,
      textSecondary = isDark
          ? ArulTokens.darkBodyWarm
          : ArulTokens.lightSecondary,
      planSecondary = isDark
          ? ArulTokens.darkTextSecondary
          : ArulTokens.lightSecondary,
      accent = isDark ? ArulTokens.gold : ArulTokens.maroon,
      cardBg = isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight,
      cardBorder = isDark
          ? ArulTokens.cardBorderDark09
          : ArulTokens.cardBorderLight,
      footnote = isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint;

  final Color bg;
  final Color textPrimary;
  final Color textSecondary;
  final Color planSecondary;
  final Color accent;
  final Color cardBg;
  final Color cardBorder;
  final Color footnote;
}

class _PremiumScreenState extends ConsumerState<PremiumScreen>
    with WidgetsBindingObserver {
  /// UPI app the user picked; null until they touch the picker, and the build
  /// falls back to the first installed app (allowlist order puts PhonePe
  /// first). No installed UPI apps → no picker → hosted-page flow.
  String? _selectedUpiPackage;

  /// Cancel-subscription in flight (kept off the purchase state machine — the
  /// confirm dialog + toast flow owns its own feedback).
  bool _cancelBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reconcileOnOpen();
    _warmOnboardingVideo();
    // A deferred delivery (Play referrer, GA4F, the Meta SDK) can report the
    // ad's language seconds after launch — possibly after a fast user is
    // already on this screen. Re-target the SURVIVING player rather than
    // rebuilding the decoder.
    ref.listenManual(localeProvider, (_, _) => _retargetOnboardingVideo());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Releases the native player, its surface and the audio focus it holds —
    // the clip is the only audible player in the app, so a leak here is a voice
    // that keeps talking over whatever screen comes next.
    unawaited(_videoPool?.dispose());
    _videoPool = null;
    _videoPlayer = null;
    super.dispose();
  }

  // ─── Onboarding clip ───────────────────────────────────────────────────────
  //
  // Owned HERE, not by the card, purely for latency. The card cannot mount
  // until `entitlementDetailProvider` resolves — until then this screen renders
  // [ArulPaywallLoading] — so leaving the player with the card put a `GET /me`
  // round trip, a platform-channel `create` and the media fetch strictly one
  // after another before a single frame could appear. Starting here overlaps
  // all three with the entitlement call. Measured cause of "the poster showed
  // for way too long"; the file itself was never the bottleneck (the CDN serves
  // it from cache in ~50ms and playback needs 250ms of buffer ≈ 18 KB).

  FeedVideoPlayerPool? _videoPool;
  FeedVideoPlayer? _videoPlayer;
  OnboardingVideoSource? _videoSource;

  Future<void> _warmOnboardingVideo() async {
    final source = resolveOnboardingVideo(
      // valueOrNull, not an await: /config may still be in flight, and the
      // resolver's defaults are the correct answer without it.
      ref.read(appConfigProvider).asData?.value,
      ref.read(localeProvider).languageCode,
    );
    if (source == null) return;
    _videoSource = source;

    final pool = FeedVideoPlayerPool();
    _videoPool = pool;
    final player = await pool.create(audio: true);
    if (player == null || !mounted) {
      await pool.dispose();
      _videoPool = null;
      return;
    }
    _videoPlayer = player;
    await _openOnboarding(source);
    if (mounted) setState(() {});
  }

  /// `playWhenReady: false` ALWAYS. This screen has no idea yet whether the
  /// user is trial-eligible, and a non-eligible one never sees the card — so
  /// the warm-up must decode a first frame without ever making a sound.
  /// Playing belongs to the card, which only does it once it is on screen.
  /// `looping: true` is the seamless loop (owner's call): a looping player also
  /// never reaches `STATE_ENDED`, which is why there is no "completed" event.
  Future<void> _openOnboarding(OnboardingVideoSource source) =>
      _videoPlayer?.open(source.url, playWhenReady: false, looping: true) ??
      Future<void>.value();

  Future<void> _retargetOnboardingVideo() async {
    if (!mounted || _videoPlayer == null) return;
    final next = resolveOnboardingVideo(
      ref.read(appConfigProvider).asData?.value,
      ref.read(localeProvider).languageCode,
    );
    if (next == null || next == _videoSource) return;
    setState(() => _videoSource = next);
    await _openOnboarding(next);
  }

  /// Returning from a UPI app is the intent flow's only "the user is back"
  /// signal (third-party apps report nothing to PhonePe on cancel) — check the
  /// server the moment it fires so an approval or a dead order resolves NOW
  /// instead of on the next poll tick.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(premiumPurchaseProvider.notifier).pollNowOnResume();
    }
  }

  /// Reconcile with PhonePe on open — but only when there is something to
  /// reconcile, so a plain free-user paywall open costs no live PhonePe call.
  ///
  ///   • `pending`: the one state a user cannot recover from on their own — a
  ///     mandate that completed at PhonePe whose S2S webhook never reached us.
  ///     Only POST /payments/status asks PhonePe directly and lets the Worker
  ///     flip the row, so we do it FOR them, silently.
  ///   • premium (trialing/active/cancelled): a user who revokes the mandate
  ///     from inside their UPI app fires NO merchant webhook, so our row can
  ///     read 'active' forever — re-check so this screen never confidently
  ///     states a plan that no longer exists.
  ///
  /// Best-effort throughout: a reconcile failure must never surface here.
  Future<void> _reconcileOnOpen() async {
    try {
      // Unconditional, and deliberately NOT gated on the cached entitlement.
      //
      // That gate read `entitlementDetailProvider`'s CACHED snapshot, which on
      // the path that matters most is stale by construction: the row only
      // becomes 'pending' at initiate, so a snapshot the feed warmed before the
      // purchase still says "no subscription" — the guard then decided there
      // was nothing to reconcile at the exact moment there was, and the screen
      // issued no request at all. A settled mandate stayed unclaimable from
      // inside the app (device 2026-08-11).
      //
      // The cost guard it existed for now lives server-side, where it is
      // reliable: a user with no subscription row gets an early return from
      // /payments/status with no PhonePe call at all, so a plain free-user
      // paywall open still costs one DB read and nothing more.
      await ref.read(premiumPurchaseProvider.notifier).refreshStatus();
    } catch (_) {
      // Offline / server fault — leave the screen exactly as it was.
    }
  }

  /// Offers the share, then closes the screen.
  ///
  /// Order matters: the sheet is shown while this route is still mounted and the
  /// pop waits for it, so the sheet can never be left floating over a screen
  /// that has gone. It is entirely skippable — "Not now" is one tap and lands in
  /// the same place as closing the screen would have.
  Future<void> _celebrate(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    await ShareMomentSheet.show(
      context,
      title: l10n.premiumCelebrateTitle,
      body: l10n.premiumCelebrateBody,
      source: 'purchase_success',
      premium: true,
    );
    if (!mounted) return;
    if (context.mounted && context.canPop()) context.pop();
  }

  Future<void> _confirmAndCancel(SubscriptionModel sub) async {
    if (_cancelBusy) return;
    final until = _formatDate(sub.currentPeriodEnd);

    final ok = await showArulConfirmDialog(
      context,
      title: 'Cancel subscription?',
      message: until == null
          ? 'Your premium access stays active until the end of the current '
                'billing period. After that you won\'t be charged again.'
          : 'Your premium access stays active until $until. After that you '
                'won\'t be charged again.',
      confirmLabel: 'Cancel it',
    );
    if (ok != true || !mounted) return;

    setState(() => _cancelBusy = true);
    final notifier = ref.read(premiumPurchaseProvider.notifier);

    // cancel() owns the message. refreshStatus() is a best-effort reconcile and
    // must never turn a successful cancel into an error — hence the separate
    // try. _cancelBusy is always cleared, so the button can't get stuck
    // spinning.
    String? error;
    try {
      error = await notifier.cancel();
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    try {
      await notifier.refreshStatus();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _cancelBusy = false);

    showArulToast(
      context,
      error ??
          (until == null
              ? 'Subscription cancelled. You keep premium until the period ends.'
              : 'Subscription cancelled. You keep premium until $until.'),
      kind: error != null ? ToastKind.error : ToastKind.success,
    );
  }

  void _startPurchase(String? targetApp) {
    final l10n = AppLocalizations.of(context);
    if (!AppConfig.hasBackend) {
      // Defensive: unreachable in shipped builds (API_BASE_URL is always
      // set). Kept for define-less local runs, where there is no Worker to
      // initiate against.
      showArulToast(context, l10n.premiumComingSoonToast);
      return;
    }
    ref.read(premiumPurchaseProvider.notifier).startTrial(targetApp: targetApp);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // PhonePe purchase flow: initiate → SDK / UPI intent → status poll →
    // refresh entitlement. Success/failure feedback is reactive so the flow
    // survives rebuilds while the SDK UI is up. On success the entitlement
    // invalidation ALSO flips this screen to the member view underneath the
    // celebration sheet — the same screen serves before and after.
    ref.listen<PurchaseState>(premiumPurchaseProvider, (prev, next) {
      switch (next) {
        case PurchaseSuccess():
          showArulToast(
            context,
            l10n.premiumWelcomeToast,
            kind: ToastKind.success,
          );
          // The single warmest moment in the app to ask for a share — and the
          // one point where the user has just decided Arul is worth paying for.
          // Awaited before the pop so the sheet is never orphaned by this route
          // disappearing beneath it.
          unawaited(_celebrate(context));
        case PurchaseError(:final message, :final cancelled):
          // A self-cancelled payment reads as neutral info, not a red failure
          // — the user changed their mind; nothing broke.
          showArulToast(
            context,
            message,
            kind: cancelled ? ToastKind.info : ToastKind.error,
          );
          ref.read(premiumPurchaseProvider.notifier).reset();
        case _:
          break;
      }
    });
    final purchase = ref.watch(premiumPurchaseProvider);
    final purchaseBusy =
        purchase is PurchaseLoading || purchase is PurchaseProcessing;

    final entitlementAsync = ref.watch(entitlementDetailProvider);
    // This route is LIGHT, always (owner's call, 2026-08-11): the paywall is
    // designed against the ivory palette only. The light theme is pinned at
    // the ROUTE level (router.dart), not here — sheets and dialogs capture
    // inherited themes from this screen's own context, which sits above
    // anything this build could wrap.
    final p = _Palette(false);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Ivory ground → dark system-bar icons, matching the light theme's own
      // overlay (theme.dart) since no AppBar is here to apply it.
      value: const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: entitlementAsync.when(
            loading: () => ArulPaywallLoading(
              onBack: () {
                if (context.canPop()) context.pop();
              },
            ),
            // A failed fetch (offline, 401, 500) falls back to the paywall
            // rather than a dead-end error card: the upsell is still a useful
            // screen, and the Worker remains the authoritative gate anyway.
            // Null entitlement = "we don't know" — the paywall then shows the
            // paid copy, never a free-day promise the server might not
            // honour.
            error: (_, _) => _paywall(p, null, purchaseBusy),
            data: (e) {
              final sub = e.subscription;
              // Only a LIVE plan gets the plan-home treatment; everything
              // else (no row, pending, expired, paused, or lapsed) is a sell.
              if (!e.isPremium || sub == null) {
                return _paywall(p, e, purchaseBusy);
              }
              return switch (sub.status) {
                SubscriptionStatus.trialing ||
                SubscriptionStatus.active => _planHome(p, sub, purchaseBusy),
                SubscriptionStatus.cancelled => _resubscribeHome(
                  p,
                  sub,
                  purchaseBusy,
                ),
                // isPremium was true, so pending/paused/expired can't reach
                // here — but the enum is exhaustive and a silent wrong screen
                // is worse than a safe one.
                _ => _paywall(p, e, purchaseBusy),
              };
            },
          ),
        ),
      ),
    );
  }

  /// Resolves which UPI app the CTA will launch: the user's pick if it is
  /// still installed, else the first allowlisted app, else null (hosted page).
  String? _resolvedUpiPackage(List<UpiApp> upiApps) => upiApps.isEmpty
      ? null
      : (upiApps.any((a) => a.packageName == _selectedUpiPackage)
            ? _selectedUpiPackage
            : upiApps.first.packageName);

  Future<void> _openUpiPicker(
    _Palette p,
    List<UpiApp> upiApps,
    String currentPackage,
  ) async {
    ArulHaptics.tap();
    final picked = await showArulSheet<String>(
      context,
      builder: (sheetContext) => _UpiPickerSheet(
        apps: upiApps,
        selectedPackage: currentPackage,
        palette: p,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _selectedUpiPackage = picked);
    }
  }

  // ─── The three states ──────────────────────────────────────────────────────

  /// The sell — `design_handoff_arul_premium`, rendered by [ArulPaywallView].
  ///
  /// This method resolves the four things that view cannot: trial eligibility,
  /// the configured price, the UPI app the CTA will launch, and whether social
  /// proof is switched on.
  Widget _paywall(_Palette p, Entitlement? entitlement, bool purchaseBusy) {
    // One free trial per user: a non-null trial_end means it was consumed.
    // Advertise the trial only from a LOADED entitlement — the Worker
    // re-checks trial_end at initiate anyway, so we must never promise a free
    // day to a user it would charge.
    final trialEligible =
        entitlement != null && entitlement.subscription?.trialEnd == null;

    final config = ref.watch(appConfigProvider).asData?.value;
    final monthlyPrice = _monthlyPrice(config?.prices);

    // Installed mandate-capable UPI apps (best-effort — empty on any failure,
    // which simply hides the picker row and keeps the hosted-page flow).
    final upiApps =
        ref.watch(installedUpiAppsProvider).asData?.value ?? const <UpiApp>[];
    final selectedUpiPackage = _resolvedUpiPackage(upiApps);
    final selectedApp = upiApps.isEmpty
        ? null
        : upiApps.firstWhere(
            (a) => a.packageName == selectedUpiPackage,
            orElse: () => upiApps.first,
          );

    // The onboarding clip is for the TRIAL SELL ONLY (owner's call): its script
    // ends "press the button below to start your 1-day trial", which is a lie
    // on the ₹199 variant a spent-trial user sees.
    //
    // `localeProvider` is WATCHED, not read: the link's language is applied by
    // DeepLinkLocaleSync through LocaleNotifier, and the deferred deliveries
    // (Play referrer, GA4F, Meta) can land seconds after launch — after a fast
    // user is already on this screen. Watching re-resolves the source and the
    // card swaps its media in place.
    // Resolved and opened back in initState, so by the time this build runs the
    // clip has been decoding for as long as `GET /me` took. `_videoPlayer` is
    // still null if the warm-up lost that race — the card mounts on its poster
    // and attaches when the player lands.
    final source = _videoSource;

    return ArulPaywallView(
      trialEligible: trialEligible,
      monthlyPrice: monthlyPrice,
      purchaseBusy: purchaseBusy,
      showSocialProof: _showSocialProof(config),
      onboardingVideo: (!trialEligible || source == null)
          ? null
          // One constant key, so a language change rebuilds into the SAME State
          // (didUpdateWidget re-attaches) rather than churning the decoder.
          : ArulOnboardingVideoCard(
              key: const ValueKey('onboarding-video'),
              player: _videoPlayer,
              source: source,
            ),
      selectedUpiApp: selectedApp,
      canChangeUpiApp: upiApps.length > 1,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      onChangeUpiApp: () => _openUpiPicker(
        p,
        upiApps,
        selectedApp?.packageName ?? upiApps.first.packageName,
      ),
      onPurchase: () => _startPurchase(selectedUpiPackage),
    );
  }

  /// `feature_flags.show_social_proof` — ON unless config says otherwise, so a
  /// config the app could not fetch never silently strips the page.
  bool _showSocialProof(AppConfigModel? config) =>
      config?.featureFlags['show_social_proof'] != false;

  /// Trialing / active: the plan stated once, billing details, Cancel.
  Widget _planHome(_Palette p, SubscriptionModel sub, bool purchaseBusy) {
    final trialing = sub.status == SubscriptionStatus.trialing;
    final renewalDate = trialing
        ? (sub.trialEnd ?? sub.currentPeriodEnd)
        : sub.currentPeriodEnd;

    return ArulMemberView(
      trialing: trialing,
      renewalDate: _formatDate(renewalDate),
      cancelBusy: _cancelBusy,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      onCancel: () => _confirmAndCancel(sub),
    );
  }

  /// Cancelled but still inside the paid period — premium, not renewing.
  /// This is why `cancelled` is in the entitlement IN-list. Resubscribe runs
  /// the SAME purchase flow inline (UPI picker + CTA) — no second screen.
  Widget _resubscribeHome(
    _Palette p,
    SubscriptionModel sub,
    bool purchaseBusy,
  ) {
    final monthlyPrice = _monthlyPrice(
      ref.watch(appConfigProvider).asData?.value?.prices,
    );
    final upiApps =
        ref.watch(installedUpiAppsProvider).asData?.value ?? const <UpiApp>[];
    final selectedUpiPackage = _resolvedUpiPackage(upiApps);
    final selectedApp = upiApps.isEmpty
        ? null
        : upiApps.firstWhere(
            (app) => app.packageName == selectedUpiPackage,
            orElse: () => upiApps.first,
          );

    return ArulResubscribeView(
      monthlyPrice: monthlyPrice,
      accessUntil: _formatDate(sub.currentPeriodEnd),
      selectedUpiApp: selectedApp,
      canChangeUpiApp: upiApps.length > 1,
      purchaseBusy: purchaseBusy,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      onChangeUpiApp: () => _openUpiPicker(
        p,
        upiApps,
        selectedApp?.packageName ?? upiApps.first.packageName,
      ),
      onResubscribe: () => _startPurchase(selectedUpiPackage),
    );
  }
}

// ─── UPI picker ──────────────────────────────────────────────────────────────

/// The picker itself — an Arul sheet listing every installed mandate-capable
/// UPI app; the tapped row pops with its package name.
class _UpiPickerSheet extends StatelessWidget {
  const _UpiPickerSheet({
    required this.apps,
    required this.selectedPackage,
    required this.palette,
  });

  final List<UpiApp> apps;
  final String selectedPackage;
  final _Palette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pay using',
            style: ArulTokens.sheetTitle.copyWith(color: p.textPrimary),
          ),
          const SizedBox(height: 6),
          for (final app in apps)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => ArulHaptics.tap(),
              onTap: () => Navigator.of(context).pop(app.packageName),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    _UpiAppIcon(app: app, size: 32, accent: p.accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        app.label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: app.packageName == selectedPackage
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    if (app.packageName == selectedPackage)
                      Icon(Icons.check_circle, size: 20, color: p.accent),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// App icon from PackageManager bytes, or the wallet glyph fallback.
class _UpiAppIcon extends StatelessWidget {
  const _UpiAppIcon({
    required this.app,
    required this.size,
    required this.accent,
  });

  final UpiApp app;
  final double size;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon == null) {
      return Icon(
        Icons.account_balance_wallet_outlined,
        size: size - 4,
        color: accent,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.memory(
        icon,
        width: size,
        height: size,
        gaplessPlayback: true,
      ),
    );
  }
}
