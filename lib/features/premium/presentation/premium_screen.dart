import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/arul_spinner.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/analytics/analytics_provider.dart';
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

/// The line a failed checkout shows, in the language the app is running in.
///
/// Resolved HERE and not in the notifier: the notifier outlives the paywall and has no locale, and
/// the toast is raised from a context that does. Exhaustive on purpose — a new kind without a
/// line is a compile error, never a silent English fallback.
@visibleForTesting
String purchaseErrorText(AppLocalizations l10n, PurchaseErrorKind kind) =>
    switch (kind) {
      PurchaseErrorKind.generic => l10n.purchaseErrorGeneric,
      PurchaseErrorKind.network => l10n.purchaseErrorNetwork,
      PurchaseErrorKind.cancelled => l10n.purchaseCancelled,
      PurchaseErrorKind.interrupted => l10n.purchaseInterrupted,
      PurchaseErrorKind.notCompleted => l10n.purchaseNotCompleted,
      PurchaseErrorKind.inProgress => l10n.purchaseInProgress,
      PurchaseErrorKind.upiLaunchFailed => l10n.purchaseUpiLaunchFailed,
      PurchaseErrorKind.intentFailed => l10n.purchaseIntentFailed,
      PurchaseErrorKind.activateFailed => l10n.purchaseActivateFailed,
      PurchaseErrorKind.confirmationLate => l10n.purchaseConfirmationLate,
    };

/// The `paywall_shown` payload — pure, so its shape is pinned by a test, not by a screen.
///
/// Every value is a STRING on purpose. GA4 does not parse numeric event-parameter values into
/// event-scoped custom dimensions on APP streams, so a count sent as `3` is collected and can never
/// be broken down; a bool is worse, since the GA4 sink coerces it to 1/0. `has_upi_app` rides beside
/// the app list because two values can never be condensed into GA4's `(other)` row, whatever the
/// combinations do.
@visibleForTesting
Map<String, Object?> paywallShownProperties({
  required String source,
  required List<UpiApp> apps,
  required String? defaultPackage,
  required bool trialEligible,
  required String variant,
  List<String> otherPackages = const [],
}) {
  // SORTED, not in picker order: the remembered app is floated to the head for the UI, and letting
  // that order reach the value would file one installed set under as many names as it has orders.
  final codes = [for (final a in apps) upiAppCode(a.packageName)]..sort();
  return {
    // `paywall_source`, never `source` — GA4 already owns `source` as a traffic dimension.
    'paywall_source': source,
    'variant': variant,
    'has_upi_app': codes.isEmpty ? 'no' : 'yes',
    'upi_app_count': _countBucket(codes.length),
    // GA4 drops a parameter value over 100 characters -> six codes is more than can ever install.
    'upi_apps': codes.isEmpty ? 'none' : codes.take(6).join(','),
    'default_app': defaultPackage == null ? 'none' : upiAppCode(defaultPackage),
    'trial_eligible': trialEligible ? 'yes' : 'no',
    // The apps the phone HAS and the allowlist refuses. `has_upi_app: no` alongside a non-zero
    // count here is not a phone that cannot pay — it is a phone we declined to sell to, and the
    // two were indistinguishable while 13% of Subscribe taps went to the SDK path.
    'upi_other_count': _countBucket(otherPackages.length),
    // RAW package names, not codes: the whole point is to learn names we do not have a code for,
    // and `other` would hide every one of them inside one word. The count above is what survives
    // truncation, so a phone carrying more names than fit still reports how many there were.
    'upi_others': otherPackages.isEmpty
        ? 'none'
        : _packWithinGa4Limit([...otherPackages]..sort()),
  };
}

/// GA4's cardinality guard for a count — a string, for the same reason every other value is one.
String _countBucket(int n) => switch (n) {
  0 => '0',
  1 => '1',
  2 => '2',
  3 => '3',
  _ => '4plus',
};

/// [values] joined with commas, taking whole entries while the result stays inside GA4's 100-char
/// parameter-value limit. A half-written package name is worse than a missing one, so nothing is
/// ever cut mid-value; going over the limit at all would make GA4 drop the parameter entirely.
String _packWithinGa4Limit(List<String> values) {
  final out = StringBuffer();
  for (final value in values) {
    final added = out.isEmpty ? value.length : out.length + 1 + value.length;
    if (added > 100) break;
    if (out.isNotEmpty) out.write(',');
    out.write(value);
  }
  // Every candidate overran on its own -> report the fact rather than an empty string, which GA4
  // cannot tell from an old build that never sent the parameter.
  return out.isEmpty ? 'toolong' : out.toString();
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
/// The gate fires its own `*_blocked_premium` at `ensurePremium`; the only event raised HERE is
/// `paywall_shown`, which carries that same verb as `paywall_source`.
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

  /// The sell state `paywall_shown` has already reported, null before the first report.
  String? _paywallShown;

  /// Reports `paywall_shown` ONCE per state of the sell — GA4 only, deliberately off the PostHog
  /// allow-list ([docs/analytics-events.md]).
  ///
  /// The signature is the variant and the INSTALLED APPS, never the whole payload: picking another
  /// app in the picker moves `default_app` and is a choice inside one view, not a second view.
  /// Installing one from the prompt does change it, and that second report is the only way the
  /// prompt's effect on a dead CTA is visible at all.
  void _trackPaywallShown(Map<String, Object?> properties) {
    final signature = '${properties['variant']}/${properties['upi_apps']}';
    if (_paywallShown == signature) return;
    _paywallShown = signature;
    // Out of the build phase — `track` reaches a platform channel, which a widget must never do
    // while it is laying out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(analyticsServiceProvider)
          .track('paywall_shown', properties: properties);
    });
  }

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
      // The installed-app set is keepAlive and changes only on an install — and someone who left
      // this screen to fetch a UPI app must come back to a picker, not to the QR.
      // Without this they come back to the same dead CTA that sent them.
      ref.invalidate(installedUpiAppsProvider);
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
    if (context.mounted) _leave();
  }

  /// Out of the premium screen. A campaign push or the trial reminder OPENS it with `go`, so nothing
  /// sits under it: a bare pop is a no-op there and the system back closes the app -> land on the feed.
  void _leave() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/browse');
    }
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

  void _startPurchase(
    String? targetApp, {
    required bool trialEligible,
    bool asQr = false,
  }) {
    final l10n = AppLocalizations.of(context);
    if (!AppConfig.hasBackend) {
      // Unreachable in shipped builds — API_BASE_URL is always set.
      // Kept for define-less local runs, where there is no Worker to initiate against.
      showArulToast(context, l10n.premiumComingSoonToast);
      return;
    }
    ref
        .read(premiumPurchaseProvider.notifier)
        .startTrial(
          targetApp: targetApp,
          trialEligible: trialEligible,
          asQr: asQr,
        );
  }

  /// The QR route: the same mandate, rendered for a second phone to scan.
  ///
  /// It still names a package. PhonePe makes `paymentMode.targetApp` mandatory on UPI_INTENT, and
  /// the `upi://mandate` they hand back carries no app binding of its own — the name is a formality
  /// their API requires, not a claim about this phone, and the Worker files the order under `qr` so
  /// the column that answers "which app completes a mandate" is not told a phone had PhonePe.
  static const _kQrFormalityPackage = 'com.phonepe.app';

  void _startQrPurchase({required bool trialEligible}) {
    ArulHaptics.tap();
    // Swiped the sheet away while the code was still live: the order is open at PhonePe and somebody
    // may be scanning it, so this re-opens THAT code rather than starting a second one. `startTrial`
    // would refuse it anyway — and a CTA that silently does nothing for the rest of the window is the
    // dead button this whole path exists to remove.
    if (ref.read(premiumPurchaseProvider) is PurchaseScannable) {
      unawaited(_openQrSheet(trialEligible: trialEligible));
      return;
    }
    _startPurchase(
      _kQrFormalityPackage,
      trialEligible: trialEligible,
      asQr: true,
    );
  }

  /// Whether a QR sheet is already up, so the listener below opens exactly one per attempt.
  /// The notifier can re-emit [PurchaseScannable] on a rebuild, and two stacked sheets would leave
  /// one behind when the state settles and pops only the top.
  /// The open QR sheet's future — it completes when the sheet is gone, which is what the success
  /// path waits on. Null whenever no sheet is up.
  Future<void>? _qrSheet;

  Future<void> _openQrSheet({required bool trialEligible}) {
    final existing = _qrSheet;
    if (existing != null || !mounted) return existing ?? Future<void>.value();
    final opened = showArulSheet<void>(
      context,
      // The paywall's own ground — the generic sheet white read as a system dialog on cream.
      surfaceColor: ArulTokens.paywallCream,
      builder: (_) => _QrMandateSheet(trialEligible: trialEligible),
    ).whenComplete(() => _qrSheet = null);
    // Dismissed by hand while the code was still live: the order stays open at PhonePe and the
    // watch keeps running, so a scan that lands after the sheet is gone still grants. Nothing is
    // abandoned here — the deadline is the only thing that retires it.
    return _qrSheet = opened;
  }

  /// Toast, then the share moment — but never over a QR sheet that is still closing.
  ///
  /// The sheet pops ITSELF the frame after the state leaves [PurchaseScannable], and the celebration
  /// pushes with no await in front of it. Stacking the two put the share sheet above a live QR sheet,
  /// and the `_leave()` that follows the celebration then popped this route out from under the one
  /// still on the stack.
  Future<void> _celebrateAfterQr(AppLocalizations l10n) async {
    await _qrSheet;
    if (!mounted) return;
    showArulToast(context, l10n.premiumWelcomeToast, kind: ToastKind.success);
    // Awaited before the pop, so the sheet is never orphaned by this route disappearing.
    await _celebrate(context);
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
          // The warmest moment to ask for a share — they have just decided Arul is worth paying for.
          unawaited(_celebrateAfterQr(l10n));
        case PurchaseScannable():
          // Trial eligibility is read from the live entitlement rather than carried in the state:
          // the notifier's job is the order, and the sheet's title is a copy decision this screen
          // already makes everywhere else.
          unawaited(
            _openQrSheet(
              trialEligible:
                  ref
                      .read(entitlementDetailProvider)
                      .asData
                      ?.value
                      .subscription
                      ?.trialEnd ==
                  null,
            ),
          );
        case PurchaseError(:final kind, :final cancelled):
          // A self-cancelled payment is neutral info, not a red failure — nothing broke.
          showArulToast(
            context,
            purchaseErrorText(l10n, kind),
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
    // The mandate is still open at PhonePe and the user is back in Arul -> the CTA becomes
    // "open it again"; picking another app in the chip, or the order's own deadline, is the only
    // other way out. Never a toast: nothing failed.
    final resumable = purchase is PurchaseResumable ? purchase : null;

    final entitlementAsync = ref.watch(entitlementDetailProvider);
    // This route is LIGHT, always (owner's call) — the paywall is designed against ivory only.
    // Sheets and dialogs inherit theme from this screen's context, above anything this build wraps.
    // So the light theme is pinned at the ROUTE level (router.dart), never here.
    final p = _Palette(false);

    // Intercepted only when nothing sits under this route (opened by a push or reminder via `go`):
    // the system back would otherwise close the app. A pushed open keeps predictive back.
    return PopScope(
      canPop: context.canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
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
              loading: () => ArulPaywallLoading(onBack: _leave),
              // A failed fetch falls back to the PAYWALL, never a dead-end error card.
              // The upsell is still useful, and the Worker remains the authoritative gate.
              // Null entitlement = "we don't know" -> show the paid copy, never a free-day promise.
              error: (_, _) => _paywall(p, null, purchaseBusy, resumable),
              data: (e) {
                final sub = e.subscription;
                // Only a LIVE plan gets the plan-home treatment; everything else is a sell.
                if (!e.isPremium || sub == null) {
                  return _paywall(p, e, purchaseBusy, resumable);
                }
                return switch (sub.status) {
                  SubscriptionStatus.trialing ||
                  SubscriptionStatus.active => _planHome(p, sub, purchaseBusy),
                  SubscriptionStatus.cancelled => _resubscribeHome(
                    p,
                    sub,
                    purchaseBusy,
                    resumable,
                  ),
                  // isPremium was true, so pending/paused/expired cannot reach here.
                  // The enum is exhaustive though, and a silent wrong screen is worse than a safe one.
                  _ => _paywall(p, e, purchaseBusy, resumable),
                };
              },
            ),
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

  /// Installed apps with the user's remembered pick floated to the head — see [UpiApps.ordered].
  List<UpiApp> _orderedUpiApps(List<UpiApp> apps) =>
      UpiApps.ordered(apps, _selectedUpiPackage);

  /// The picker, open in EVERY state including a resumable one.
  ///
  /// An order already open at PhonePe never narrows the choice to the app holding it: picking a
  /// different one there is a decision to pay with that app instead, and [PremiumPurchase.switchApp]
  /// carries it out in one motion — this order abandoned, a fresh one initiated in the new app.
  /// Picking the app that already holds the order changes nothing at all.
  Future<void> _openUpiPicker(
    List<UpiApp> upiApps,
    String currentPackage, {
    PurchaseResumable? resumable,
    required bool trialEligible,
  }) async {
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
    if (!mounted || resumable == null || picked == resumable.targetApp) return;
    await ref
        .read(premiumPurchaseProvider.notifier)
        .switchApp(picked, trialEligible: trialEligible);
  }

  /// The sell — `design_handoff_arul_premium`, rendered by [ArulPaywallView].
  ///
  /// Resolves the four things that view cannot: trial eligibility, price, the UPI app, social proof.
  Widget _paywall(
    _Palette p,
    Entitlement? entitlement,
    bool purchaseBusy,
    PurchaseResumable? resumable,
  ) {
    // One free trial per user -> a non-null trial_end means it was consumed.
    // Advertise the trial only from a LOADED entitlement — never promise a day the Worker charges.
    final trialEligible =
        entitlement != null && entitlement.subscription?.trialEnd == null;

    final config = ref.watch(appConfigProvider).asData?.value;
    final monthlyPrice = _monthlyPrice(config?.prices);

    // Installed mandate-capable UPI apps — best-effort. Empty AND answered puts the install prompt
    // in the picker's place and kills the CTA; empty and still loading shows neither.
    final upiAsync = ref.watch(installedUpiAppsProvider);
    final upiScan = upiAsync.asData?.value ?? const UpiScan.empty();
    final upiApps = _orderedUpiApps(upiScan.apps);
    final selectedUpiPackage = _resolvedUpiPackage(upiApps);
    final selectedApp = upiApps.isEmpty
        ? null
        : upiApps.firstWhere(
            (a) => a.packageName == selectedUpiPackage,
            orElse: () => upiApps.first,
          );

    // Reported only once the app probe has ANSWERED: the first build here always has an empty list,
    // and reporting that would stamp "no UPI app" on every install that ever opened the paywall.
    if (upiAsync.hasValue) {
      _trackPaywallShown(
        paywallShownProperties(
          source: widget.source,
          apps: upiScan.apps,
          otherPackages: upiScan.otherPackages,
          defaultPackage: selectedUpiPackage,
          trialEligible: trialEligible,
          // No entitlement is the FAILED fetch, which renders the paid copy without knowing it is
          // right -> its own bucket, so it can never be read as a real trial/paid split.
          variant: entitlement == null
              ? 'unknown'
              : (trialEligible ? 'trial' : 'paid'),
        ),
      );
    }

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
      resumeAppLabel: _resumeAppLabel(resumable, upiApps, selectedApp),
      onResume: _resume,
      onBack: _leave,
      // While resumable the highlighted row is the ORDER's app, not the picker's idea of current —
      // the same app the CTA above promises to re-open.
      onChangeUpiApp: () => _openUpiPicker(
        upiApps,
        resumable?.targetApp ??
            selectedApp?.packageName ??
            upiApps.first.packageName,
        resumable: resumable,
        trialEligible: trialEligible,
      ),
      onPurchase: () =>
          _startPurchase(selectedUpiPackage, trialEligible: trialEligible),
      // Non-null ONLY where there is nothing to launch, and then it IS the CTA. With an app
      // installed the QR is strictly worse than the one tap that opens its mandate sheet; without
      // one it is the only thing that can finish, so it needs no separate affordance.
      onPayByQr: upiApps.isEmpty && upiAsync.hasValue
          ? () => _startQrPurchase(trialEligible: trialEligible)
          : null,
    );
  }

  /// The label of the app the live mandate link was fired at — the one named by the resume copy.
  /// Null whenever there is nothing to resume, which is what switches the footer over.
  /// It is the ATTEMPT's app, never the picker's: the button must promise the app that actually
  /// holds the half-finished sheet. The two DO diverge for the length of a switch — the chip shows
  /// the app just picked while this line still names the order being abandoned for it.
  String? _resumeAppLabel(
    PurchaseResumable? resumable,
    List<UpiApp> apps,
    UpiApp? selected,
  ) {
    if (resumable == null) return null;
    for (final app in apps) {
      if (app.packageName == resumable.targetApp) return app.label;
    }
    return selected?.label ?? AppLocalizations.of(context).premiumUpiAppGeneric;
  }

  void _resume() =>
      unawaited(ref.read(premiumPurchaseProvider.notifier).resumeIntent());

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
      onBack: _leave,
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
    PurchaseResumable? resumable,
  ) {
    final monthlyPrice = _monthlyPrice(
      ref.watch(appConfigProvider).asData?.value?.prices,
    );
    final upiAsync = ref.watch(installedUpiAppsProvider);
    final upiScan = upiAsync.asData?.value ?? const UpiScan.empty();
    final upiApps = _orderedUpiApps(upiScan.apps);
    final selectedUpiPackage = _resolvedUpiPackage(upiApps);
    final selectedApp = upiApps.isEmpty
        ? null
        : upiApps.firstWhere(
            (app) => app.packageName == selectedUpiPackage,
            orElse: () => upiApps.first,
          );

    if (upiAsync.hasValue) {
      _trackPaywallShown(
        paywallShownProperties(
          source: widget.source,
          apps: upiScan.apps,
          otherPackages: upiScan.otherPackages,
          defaultPackage: selectedUpiPackage,
          // A resubscribe is never a trial — the row already carries a spent `trial_end`.
          trialEligible: false,
          variant: 'resubscribe',
        ),
      );
    }

    return ArulResubscribeView(
      monthlyPrice: monthlyPrice,
      accessUntil: _formatDate(sub.currentPeriodEnd),
      selectedUpiApp: selectedApp,
      canChangeUpiApp: upiApps.length > 1,
      purchaseBusy: purchaseBusy,
      resumeAppLabel: _resumeAppLabel(resumable, upiApps, selectedApp),
      onResume: _resume,
      onBack: _leave,
      onChangeUpiApp: () => _openUpiPicker(
        upiApps,
        resumable?.targetApp ??
            selectedApp?.packageName ??
            upiApps.first.packageName,
        resumable: resumable,
        // A resubscribe is never a trial — the row already carries a spent `trial_end`.
        trialEligible: false,
      ),
      // Same rule as the paywall: with nothing installed, `_startPurchase(null)` fell through to the
      // SDK page — not a dead CTA but a worse one, since that page needs an app on this very phone.
      onResubscribe: upiApps.isEmpty && upiAsync.hasValue
          ? () => _startQrPurchase(trialEligible: false)
          : () => _startPurchase(selectedUpiPackage, trialEligible: false),
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
                for (final (i, app) in apps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _UpiOptionRow(
                      app: app,
                      // The INDEX is the identifier: row 0 is the head of the
                      // channel's preference order, which is what the rig asserts.
                      identifier: 'arul_upi_option_$i',
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
    required this.identifier,
  });

  final UpiApp app;
  final bool selected;
  final bool lastUsed;
  final VoidCallback onTap;

  /// Stable accessibility id (`Semantics(identifier:)`): announced to nobody, so it is free at
  /// the UI layer and survives every locale.
  /// Never announced and never visible — see that folder's README for the list.
  final String identifier;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      identifier: identifier,
      label: app.label,
      selected: selected,
      child: GestureDetector(
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

/// The mandate link as a scannable QR, for a phone with no UPI app of its own.
///
/// Opened by [PremiumScreen]'s purchase listener the moment the notifier reaches
/// [PurchaseScannable], and it closes ITSELF the moment the state leaves that — settled, expired or
/// disposed. The sheet owns no order and no deadline: both live on the state it watches, so a
/// rebuild, a rotation or a backgrounded process cannot desynchronise the code on screen from the
/// one PhonePe is holding.
class _QrMandateSheet extends ConsumerStatefulWidget {
  const _QrMandateSheet({required this.trialEligible});

  /// The title may not promise a trial to someone who has spent theirs.
  final bool trialEligible;

  @override
  ConsumerState<_QrMandateSheet> createState() => _QrMandateSheetState();
}

class _QrMandateSheetState extends ConsumerState<_QrMandateSheet> {
  /// Drives the countdown text only. The DEADLINE is never this timer's business — it is read off
  /// the clock against the state's `expiresAt` on every tick, because Android freezes a backgrounded
  /// process and every Dart timer inside it, and a frozen timer would show a code as live for as
  /// long as the phone was asleep.
  Timer? _tick;

  /// True for the one round-trip behind the Check button — its own spinner, never the waiting line's.
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// `4:32`, floored at zero — the last second reads 0:00 rather than going negative.
  String _remaining(DateTime expiresAt) {
    final left = expiresAt.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : left.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _check() async {
    ArulHaptics.tap();
    setState(() => _checking = true);
    await ref.read(premiumPurchaseProvider.notifier).checkQrStatus();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(premiumPurchaseProvider);
    // Settled, expired, or the notifier is gone: there is nothing left to scan, so the sheet leaves.
    // Popped from a post-frame callback — a Navigator.pop inside build is a reentrant-navigation
    // crash, and this widget rebuilds from a provider it does not control.
    if (state is! PurchaseScannable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 2, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.trialEligible
                ? l10n.premiumQrTitleTrial
                : l10n.premiumQrTitlePaid,
            textAlign: TextAlign.center,
            style: ArulTokens.paywallWordmark.copyWith(
              fontSize: 19,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 14),
          // White behind the code, always: a QR on Arul's cream reads at a lower contrast ratio
          // than the spec asks of a scanner, and the one on the other phone may be an old camera.
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: ArulTokens.paywallBorderControl),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: QrImageView(
                // The link VERBATIM — PhonePe's `upi://mandate?...`, never rebuilt from its parts.
                data: state.intentUrl,
                version: QrVersions.auto,
                size: 220,
                // Highest redundancy the payload allows: it is scanned off a screen, at an angle,
                // by a second phone, and a mandate link is long enough that a retry costs the
                // person most of a five-minute window.
                errorCorrectionLevel: QrErrorCorrectLevel.H,
                backgroundColor: Colors.white,
                // Pure black, not the maroon: scanners threshold on luminance and a brand colour
                // buys nothing here but a lower success rate on a cheap camera.
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.premiumQrInstruction,
            textAlign: TextAlign.center,
            style: ArulTokens.paywallUpiLabel,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.premiumQrExpiresIn(_remaining(state.expiresAt)),
            textAlign: TextAlign.center,
            style: ArulTokens.paywallUpiName.copyWith(
              color: ArulTokens.lightSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const ArulSpinner(
                size: 14,
                strokeWidth: 2,
                color: ArulTokens.maroon,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  l10n.premiumQrWaiting,
                  style: ArulTokens.paywallUpiLabel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Asks the server sooner; it can settle nothing the watch would not. So it is a quiet
          // secondary control, never the CTA — the sheet resolves itself without anyone pressing it.
          Semantics(
            button: true,
            identifier: 'arul_qr_check',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _checking ? null : _check,
              child: SizedBox(
                height: ArulTokens.minHitTarget,
                child: Center(
                  child: _checking
                      ? const ArulSpinner(
                          size: 16,
                          strokeWidth: 2,
                          color: ArulTokens.maroon,
                        )
                      : Text(
                          l10n.premiumQrCheck,
                          style: ArulTokens.paywallUpiName.copyWith(
                            color: ArulTokens.maroon,
                            decoration: TextDecoration.underline,
                            decorationColor: ArulTokens.maroon,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
