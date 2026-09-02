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
import '../../../core/providers/shared_preferences_provider.dart';
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

/// Monthly price from app_config `prices` (paise) → "₹199", falling back to the launch price.
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

/// THE premium screen — paywall and plan home in ONE route.
///
/// Two screens made a free user tap "premium" twice to see a price -> `/premium` renders the state:
///   • no plan / expired / paused / pending → the paywall (perks, plan card, UPI picker, CTA);
///   • trialing / active                   → plan + billing details + Cancel;
///   • cancelled, still paid-through       → "auto-renew off" + billing + an INLINE Resubscribe.
///
/// `source` is the blocked verb that sent the user here — which entry point actually sells.
/// Tracking happens at the gate (`ensurePremium`), never here.
/// This is also the only route that can reach `POST /payments/cancel`.
class PremiumScreen extends ConsumerStatefulWidget {
  const PremiumScreen({super.key, required this.source});

  final String source;

  @override
  ConsumerState<PremiumScreen> createState() => _PremiumScreenState();
}

/// Shared colour resolution for every state this screen renders — resolved ONCE per build.
/// So the paywall, the billing card and the picker sheet cannot drift apart on theme.
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

/// The UPI app the user last picked. Survives leaving `/premium`, which is the whole point:
/// most setups die inside the UPI handoff, so the SECOND attempt is the common one — and while
/// this lived in a State field, every retry silently reset the user to the allowlist head.
const _kUpiAppKey = 'arul_upi_app';

class _PremiumScreenState extends ConsumerState<PremiumScreen>
    with WidgetsBindingObserver {
  /// UPI app the user picked, restored from [_kUpiAppKey] on open.
  /// The build then falls back to the first installed app — allowlist order puts Paytm first.
  /// No installed UPI apps → no picker → the hosted-page flow.
  String? _selectedUpiPackage;

  /// Cancel-subscription in flight, kept OFF the purchase state machine — the dialog owns feedback.
  bool _cancelBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Synchronous by construction — `sharedPreferencesProvider` is overridden in main() after its await.
    _selectedUpiPackage = ref
        .read(sharedPreferencesProvider)
        .getString(_kUpiAppKey);
    _reconcileOnOpen();
    _warmOnboardingVideo();
    // A deferred delivery can report the ad's language seconds after launch, past a fast user.
    // Re-target the SURVIVING player rather than rebuilding the decoder.
    ref.listenManual(localeProvider, (_, _) => _retargetOnboardingVideo());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Releases the native player, its surface and its audio focus.
    // The clip is the app's only audible player -> a leak here is a voice over the next screen.
    unawaited(_videoPool?.dispose());
    _videoPool = null;
    _videoPlayer = null;
    super.dispose();
  }

  // The clip's player is owned HERE, not by the card, purely for latency.
  // The card cannot mount until `entitlementDetailProvider` resolves.
  // So leaving the player with it serialised `GET /me`, a channel `create` and the media fetch.
  // Starting here overlaps all three with the entitlement call.
  // Measured cause of "the poster showed for way too long" — the file was never the bottleneck.

  FeedVideoPlayerPool? _videoPool;
  FeedVideoPlayer? _videoPlayer;
  OnboardingVideoSource? _videoSource;

  Future<void> _warmOnboardingVideo() async {
    final source = resolveOnboardingVideo(
      // valueOrNull, not an await -> /config may be in flight, and the defaults are correct anyway.
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

  /// `playWhenReady: false` ALWAYS — this screen does not yet know if the user is trial-eligible.
  /// A non-eligible one never sees the card -> the warm-up decodes a frame without making a sound.
  /// Playing belongs to the card, once it is on screen.
  /// `looping: true` is the seamless loop -> a looping player never reaches `STATE_ENDED`.
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

  /// Returning from a UPI app is the intent flow's ONLY "the user is back" signal.
  /// Third-party apps report nothing to PhonePe on cancel -> check the server the moment it fires.
  /// So an approval or a dead order resolves NOW instead of on the next poll tick.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(premiumPurchaseProvider.notifier).pollNowOnResume();
    }
  }

  /// Reconcile with PhonePe on open, but only when there is something to reconcile.
  ///
  ///   • `pending` — the one state a user cannot recover from: a mandate PhonePe completed whose
  ///     S2S webhook never reached us. Only POST /payments/status asks PhonePe directly;
  ///   • premium — revoking the mandate inside a UPI app fires NO merchant webhook, so our row can
  ///     read 'active' forever. Re-check, or this screen states a plan that no longer exists.
  ///
  /// Best-effort throughout: a reconcile failure must never surface here.
  Future<void> _reconcileOnOpen() async {
    try {
      // Unconditional, and deliberately NOT gated on the cached entitlement.
      //
      // The row only becomes 'pending' at initiate -> a snapshot warmed before the purchase is stale.
      // The guard then found nothing to reconcile at the exact moment there was something.
      // A settled mandate stayed unclaimable from inside the app.
      // The cost guard now lives server-side: no subscription row -> an early return, no PhonePe call.
      await ref.read(premiumPurchaseProvider.notifier).refreshStatus();
    } catch (_) {
      // Offline or server fault — leave the screen exactly as it was.
    }
  }

  /// Offers the share, then closes the screen.
  ///
  /// Order matters — the sheet shows while this route is mounted, and the pop waits for it.
  /// So it can never be left floating over a screen that has gone.
  /// Entirely skippable: "Not now" is one tap and lands where closing the screen would.
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

    // cancel() owns the message; refreshStatus() is a best-effort reconcile in its own try.
    // A reconcile must never turn a successful cancel into an error.
    // _cancelBusy is always cleared, so the button cannot get stuck spinning.
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
      // Unreachable in shipped builds — API_BASE_URL is always set.
      // Kept for define-less local runs, where there is no Worker to initiate against.
      showArulToast(context, l10n.premiumComingSoonToast);
      return;
    }
    ref.read(premiumPurchaseProvider.notifier).startTrial(targetApp: targetApp);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // PhonePe flow: initiate → SDK/UPI intent → status poll → refresh entitlement.
    // Feedback is REACTIVE -> the flow survives rebuilds while the SDK UI is up.
    // On success the invalidation flips this screen to the member view under the celebration sheet.
    ref.listen<PurchaseState>(premiumPurchaseProvider, (prev, next) {
      switch (next) {
        case PurchaseSuccess():
          showArulToast(
            context,
            l10n.premiumWelcomeToast,
            kind: ToastKind.success,
          );
          // The warmest moment to ask for a share — they have just decided Arul is worth paying for.
          // Awaited before the pop, so the sheet is never orphaned by this route disappearing.
          unawaited(_celebrate(context));
        case PurchaseError(:final message, :final cancelled):
          // A self-cancelled payment is neutral info, not a red failure — nothing broke.
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
    // This route is LIGHT, always (owner's call) — the paywall is designed against ivory only.
    // Sheets and dialogs inherit theme from this screen's context, above anything this build wraps.
    // So the light theme is pinned at the ROUTE level (router.dart), never here.
    final p = _Palette(false);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Ivory ground → dark system-bar icons; no AppBar here to apply the theme's own overlay.
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
            // A failed fetch falls back to the PAYWALL, never a dead-end error card.
            // The upsell is still useful, and the Worker remains the authoritative gate.
            // Null entitlement = "we don't know" -> show the paid copy, never a free-day promise.
            error: (_, _) => _paywall(p, null, purchaseBusy),
            data: (e) {
              final sub = e.subscription;
              // Only a LIVE plan gets the plan-home treatment; everything else is a sell.
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
                // isPremium was true, so pending/paused/expired cannot reach here.
                // The enum is exhaustive though, and a silent wrong screen is worse than a safe one.
                _ => _paywall(p, e, purchaseBusy),
              };
            },
          ),
        ),
      ),
    );
  }

  /// Which UPI app the CTA launches — the user's pick if still installed, else the first allowlisted.
  /// Null when none is installed, which means the hosted page.
  String? _resolvedUpiPackage(List<UpiApp> upiApps) => upiApps.isEmpty
      ? null
      : (upiApps.any((a) => a.packageName == _selectedUpiPackage)
            ? _selectedUpiPackage
            : upiApps.first.packageName);

  /// Installed apps with the user's remembered pick floated to the head.
  /// Everything below it keeps `MANDATE_APPS` order — one personal row, then the owner's order.
  /// Android exposes no permission-free "most used app" signal, so our own memory IS that signal.
  List<UpiApp> _orderedUpiApps(List<UpiApp> apps) {
    final remembered = _selectedUpiPackage;
    if (remembered == null) return apps;
    final at = apps.indexWhere((a) => a.packageName == remembered);
    // -1 = uninstalled since they picked it; 0 = already the head. Neither needs reordering.
    if (at <= 0) return apps;
    return [apps[at], ...apps.where((a) => a.packageName != remembered)];
  }

  Future<void> _openUpiPicker(
    List<UpiApp> upiApps,
    String currentPackage,
  ) async {
    ArulHaptics.tap();
    final picked = await showArulSheet<String>(
      context,
      // The paywall's own ground — the generic sheet white read as a system dialog on cream.
      surfaceColor: ArulTokens.paywallCream,
      builder: (sheetContext) => _UpiPickerSheet(
        apps: upiApps,
        selectedPackage: currentPackage,
        rememberedPackage: _selectedUpiPackage,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedUpiPackage = picked);
    await ref.read(sharedPreferencesProvider).setString(_kUpiAppKey, picked);
  }

  /// The sell — `design_handoff_arul_premium`, rendered by [ArulPaywallView].
  ///
  /// Resolves the four things that view cannot: trial eligibility, price, the UPI app, social proof.
  Widget _paywall(_Palette p, Entitlement? entitlement, bool purchaseBusy) {
    // One free trial per user -> a non-null trial_end means it was consumed.
    // Advertise the trial only from a LOADED entitlement — never promise a day the Worker charges.
    final trialEligible =
        entitlement != null && entitlement.subscription?.trialEnd == null;

    final config = ref.watch(appConfigProvider).asData?.value;
    final monthlyPrice = _monthlyPrice(config?.prices);

    // Installed mandate-capable UPI apps — best-effort; empty hides the row, keeping the hosted page.
    final upiApps = _orderedUpiApps(
      ref.watch(installedUpiAppsProvider).asData?.value ?? const <UpiApp>[],
    );
    final selectedUpiPackage = _resolvedUpiPackage(upiApps);
    final selectedApp = upiApps.isEmpty
        ? null
        : upiApps.firstWhere(
            (a) => a.packageName == selectedUpiPackage,
            orElse: () => upiApps.first,
          );

    // The clip is for the TRIAL SELL ONLY — its script ends "start your 1-day trial".
    // That is a lie on the ₹199 variant a spent-trial user sees.
    // `localeProvider` is WATCHED, not read: deferred deliveries can land after the user arrives.
    // Watching re-resolves the source, and the card swaps its media in place.
    // Opened back in initState -> by this build the clip has decoded for as long as `GET /me` took.
    // `_videoPlayer` is null if the warm-up lost that race — the card mounts on its poster instead.
    final source = _videoSource;

    return ArulPaywallView(
      trialEligible: trialEligible,
      monthlyPrice: monthlyPrice,
      purchaseBusy: purchaseBusy,
      showSocialProof: _showSocialProof(config),
      onboardingVideo: (!trialEligible || source == null)
          ? null
          // One constant key -> a language change rebuilds into the SAME State, never a new decoder.
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
        upiApps,
        selectedApp?.packageName ?? upiApps.first.packageName,
      ),
      onPurchase: () => _startPurchase(selectedUpiPackage),
    );
  }

  /// `feature_flags.show_social_proof` — ON unless config says otherwise.
  /// So a config the app could not fetch never silently strips the page.
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
  /// This is why `cancelled` is in the entitlement IN-list.
  /// Resubscribe runs the SAME purchase flow inline (UPI picker + CTA) — no second screen.
  Widget _resubscribeHome(
    _Palette p,
    SubscriptionModel sub,
    bool purchaseBusy,
  ) {
    final monthlyPrice = _monthlyPrice(
      ref.watch(appConfigProvider).asData?.value?.prices,
    );
    final upiApps = _orderedUpiApps(
      ref.watch(installedUpiAppsProvider).asData?.value ?? const <UpiApp>[],
    );
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
        upiApps,
        selectedApp?.packageName ?? upiApps.first.packageName,
      ),
      onResubscribe: () => _startPurchase(selectedUpiPackage),
    );
  }
}

/// The picker — an Arul sheet listing every installed mandate-capable UPI app.
/// The tapped row pops with its package name.
///
/// Rendered in the PAYWALL's system, not `_Palette`: the sheet opens over a hand-built cream and
/// maroon screen, and a stock white list carrying the app's GENERIC maroon put two different
/// maroons on one screen. `showArulSheet` gets `paywallCream` for the same reason.
///
/// Deliberately carries NO price and NO mandate footer (owner's call). Both live on the paywall
/// behind it, and repeating them here made the sheet read as a second checkout step.
class _UpiPickerSheet extends StatelessWidget {
  const _UpiPickerSheet({
    required this.apps,
    required this.selectedPackage,
    required this.rememberedPackage,
  });

  final List<UpiApp> apps;
  final String selectedPackage;

  /// The app a previous visit settled on — the one row that earns the "Last used" badge.
  /// Null until they have ever picked; [_orderedUpiApps] has already floated it to the head.
  final String? rememberedPackage;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 13),
          child: Text(
            AppLocalizations.of(context).upiPickerTitle,
            style: ArulTokens.paywallWordmark.copyWith(
              fontSize: 19,
              height: 1.25,
            ),
          ),
        ),
        // The paywall's own header rule -> the sheet reads as part of that screen.
        Container(
          height: 1,
          decoration: const BoxDecoration(
            gradient: ArulTokens.paywallHeaderHairline,
          ),
        ),
        // Six installed apps at 1.3x text scale overrun a short viewport -> scroll, never overflow.
        // `showArulSheet` stays isScrollControlled, so the sheet itself still sizes to its content.
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final app in apps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _UpiOptionRow(
                      app: app,
                      selected: app.packageName == selectedPackage,
                      lastUsed: app.packageName == rememberedPackage,
                      onTap: () => Navigator.of(context).pop(app.packageName),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One app in the picker, built so no translation can overflow it.
///
/// The overflow matrix demotes an overflowing KEY, and one demoted key sends the whole section
/// English (`EnglishOnly`) -> on this screen that is all-or-nothing, so the row has to be safe by
/// CONSTRUCTION rather than by measurement. Three rules do it: the icon is fixed and sits outside
/// the flexible column, name and badge share a `Wrap` so a long locale drops the badge to its own
/// line instead of pushing the row over, and every text is capped to the row's OWN constraints.
class _UpiOptionRow extends StatelessWidget {
  const _UpiOptionRow({
    required this.app,
    required this.selected,
    required this.lastUsed,
    required this.onTap,
  });

  final UpiApp app;
  final bool selected;
  final bool lastUsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => ArulHaptics.tap(),
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? ArulTokens.paywallMedallionFill
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? ArulTokens.paywallGold600
                : ArulTokens.paywallBorderSoft,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Padding(
          // Compensates the thicker selected border -> the icon never shifts between states.
          padding: EdgeInsets.all(selected ? 10.5 : 11),
          child: Row(
            children: [
              // Never shrinks: the launcher icon is the row's recognition cue and the only
              // locale-invariant thing in it -> everything else reflows around it.
              _UpiAppIcon(app: app, size: 44),
              const SizedBox(width: 13),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // The label is the OS's own, already in the user's locale -> never an ARB key.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth,
                        ),
                        child: Text(
                          app.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ArulTokens.paywallUpiName.copyWith(
                            fontSize: 14.5,
                            height: 1.25,
                            color: selected
                                ? ArulTokens.paywallMaroon
                                : ArulTokens.paywallInkUpi,
                          ),
                        ),
                      ),
                      if (lastUsed)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth,
                          ),
                          child: const _LastUsedBadge(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Last used" — the remembered pick made visible, so a returning user can see we kept it.
class _LastUsedBadge extends StatelessWidget {
  const _LastUsedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ArulTokens.paywallBorderPill),
      ),
      child: Text(
        AppLocalizations.of(context).upiPickerLastUsed,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ArulTokens.paywallPill.copyWith(
          fontSize: 9.5,
          height: 1.2,
          letterSpacing: 0.95,
          color: ArulTokens.paywallInkGold,
        ),
      ),
    );
  }
}

/// App icon from PackageManager bytes, or the wallet glyph fallback.
class _UpiAppIcon extends StatelessWidget {
  const _UpiAppIcon({required this.app, required this.size});

  final UpiApp app;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Icon(
          Icons.account_balance_wallet_outlined,
          size: size - 12,
          color: ArulTokens.paywallGoldDeep,
        ),
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
