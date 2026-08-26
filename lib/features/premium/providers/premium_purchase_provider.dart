import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:phonepe_payment_sdk/phonepe_payment_sdk.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/app_instance_id.dart';
import '../../../core/analytics/meta_anon_id.dart';
import '../../../core/api/api_client.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../features/auth/providers/auth_providers.dart';
import 'entitlement_provider.dart';

part 'premium_purchase_provider.g.dart';

// ─── Purchase state ──────────────────────────────────────────────────────────

sealed class PurchaseState {
  const PurchaseState();
}

final class PurchaseIdle extends PurchaseState {
  const PurchaseIdle();
}

final class PurchaseLoading extends PurchaseState {
  const PurchaseLoading();
}

/// SDK launched; waiting for the user to complete/cancel in PhonePe.
final class PurchaseProcessing extends PurchaseState {
  const PurchaseProcessing();
}

final class PurchaseSuccess extends PurchaseState {
  const PurchaseSuccess();
}

final class PurchaseError extends PurchaseState {
  const PurchaseError(this.message, {this.cancelled = false});
  final String message;

  /// True when the user backed out of the PhonePe flow themselves — the UI
  /// shows a neutral "cancelled" toast instead of a red failure.
  final bool cancelled;
}

// ─── Notifier ─────────────────────────────────────────────────────────────────

/// Manages the PhonePe Standard Checkout trial-start flow.
///
/// Flow:
///   1. POST /payments/initiate  → get orderId / token / merchantId / environment
///   2. PhonePePaymentSdk.init() with the returned environment + merchantId
///   3. PhonePePaymentSdk.startTransaction() with the order payload
///   4. Poll POST /payments/status until status ∈ {trialing, active}
///   5. Invalidate entitlementProvider so the UI reflects the new state
@Riverpod(keepAlive: false)
class PremiumPurchase extends _$PremiumPurchase {
  @override
  PurchaseState build() => const PurchaseIdle();

  // ── Internal helpers ──────────────────────────────────────────────────────

  ApiClient get _api => ref.read(apiClientProvider);

  /// Tracks a ★ conversion event (`trial_started` / `subscription_active`) with
  /// the monthly price + order id. Fans out to PostHog + Meta via the composite
  /// [AnalyticsService]; Meta maps it to StartTrial / Subscribe with the INR
  /// value for ROAS. Best-effort — a missing price just omits the value.
  void _trackConversion(String event, String merchantOrderId) {
    final price = _monthlyPriceRupees();
    ref
        .read(analyticsServiceProvider)
        .track(
          event,
          properties: {
            'plan': 'monthly',
            'order_id': merchantOrderId,
            // Null-aware element: omitted entirely when the price hasn't loaded.
            'value': ?price,
          },
        );
  }

  /// Fires `checkout_started` the moment the user commits to paying — BEFORE
  /// /payments/initiate, so a server-side initiate failure still shows up as an
  /// abandoned checkout rather than vanishing.
  ///
  /// This is the funnel's missing middle. Everything between the paywall and
  /// `trial_started` used to be dark, which is why the UPI-handoff loss had to
  /// be reconstructed by hand from PhonePe + Neon. GA4 maps it to the standard
  /// `begin_checkout` and Meta to InitiateCheckout, so both optimisers finally
  /// see the top of the paid funnel and not just its (much rarer) endpoint.
  ///
  /// [method] records which handoff was ATTEMPTED, not which ran: the server
  /// silently falls back to the SDK shape when an intent setup fails, so this
  /// is the user's intent. `target_app` is the UPI package — the axis that
  /// makes "which app expires the mandate" answerable.
  void _trackCheckoutStarted(String method, String? targetApp) {
    _checkoutMethod = method;
    final price = _monthlyPriceRupees();
    ref
        .read(analyticsServiceProvider)
        .track(
          'checkout_started',
          properties: {
            'plan': 'monthly',
            'method': method,
            'target_app': ?targetApp,
            'value': ?price,
          },
        );
  }

  /// The ONE terminal-failure event, emitted through [_fail] so no error path
  /// can be added without one. GA4-only by construction: `payment_failed` is
  /// not on the PostHog allow-list (default-deny, analytics-events.md) and
  /// `MetaAnalyticsService` drops anything that isn't a conversion — a failure
  /// is a diagnostic, and feeding it to an ad optimiser trains the wrong thing.
  ///
  /// [reason] is a short STABLE code, never the user-facing copy: that copy is
  /// prose, it changes for wording reasons, and it would fragment the metric.
  /// `cancelled` separates a deliberate back-out from a real failure — the same
  /// split `login_cancelled` keeps against `login_failed`.
  void _trackPaymentFailed(String reason, {required bool cancelled}) {
    ref
        .read(analyticsServiceProvider)
        .track(
          'payment_failed',
          properties: {
            'reason': reason,
            'cancelled': cancelled,
            'plan': 'monthly',
            // Which handoff was in flight when it died — the whole point of
            // the event. Null only if a failure somehow precedes the tap.
            'method': ?_checkoutMethod,
          },
        );
  }

  /// Terminal failure: set the error state AND report it, in that order, so
  /// every one of this notifier's failure exits is counted exactly once.
  /// Always prefer this over assigning [PurchaseError] directly.
  void _fail(String reason, PurchaseError error) {
    state = error;
    _trackPaymentFailed(reason, cancelled: error.cancelled);
  }

  /// The checkout handoff currently in flight (`upi_app` / `phonepe_sdk`), set
  /// by [_trackCheckoutStarted] and read by [_trackPaymentFailed] so a failure
  /// names the path that died. Survives for the attempt's lifetime.
  String? _checkoutMethod;

  /// Monthly price in rupees from the remote app_config (`prices.monthly.amount`
  /// is paise), or null if the config hasn't loaded — matches the fallback the
  /// premium screen uses for display. Read synchronously from the already-cached
  /// provider (the paywall watched it), so no await on the success path.
  double? _monthlyPriceRupees() {
    final prices = ref.read(appConfigProvider).asData?.value?.prices;
    final monthly = prices?['monthly'];
    if (monthly is Map && monthly['amount'] is num) {
      return (monthly['amount'] as num) / 100;
    }
    return null;
  }

  /// Deep-link return scheme registered in AndroidManifest.xml.
  /// PhonePe uses this to bring the app back to the foreground after payment.
  static const _appSchema = 'arul';

  /// SDK-path confirmation poll: the SDK callback already said the sheet
  /// closed with SUCCESS, so the webhook/reconcile is seconds away.
  static const _sdkPollDelays = [1, 2, 3, 5, 8];

  /// Intent-path confirmation poll: the user is off in their UPI app reading
  /// the mandate sheet and entering a PIN — approval routinely takes a minute.
  /// ~2 minutes total before giving up (the webhook still grants later; the
  /// paywall's pending self-heal picks it up on reopen).
  static const _intentPollDelays = [
    4, 4, 4, 5, 5, 6, 8, 8, 10, 10, 10, 10, 10, 10, 10, 10, //
  ];

  /// The merchant order id of an intent-flow setup currently awaiting UPI-app
  /// approval — the handle [cancelPending] needs. Null outside that window.
  String? _intentOrderId;

  /// Bumped to cancel a running [_confirmWithServer] loop: the loop captures
  /// the value at entry and goes silent when it changes, so a user-tapped
  /// cancel can own the next state without racing a late poll response.
  int _pollGeneration = 0;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Starts the 1-day free trial via PhonePe.
  ///
  /// [targetApp] (Android package of a mandate-capable UPI app) selects the
  /// direct UPI-intent flow: the chosen app opens straight onto its AutoPay
  /// sheet, no hosted page. Null → the PhonePe SDK hosted-page flow.
  Future<void> startTrial({String? targetApp}) async {
    if (state is PurchaseLoading || state is PurchaseProcessing) return;

    state = const PurchaseLoading();
    // The user has committed to paying — count the checkout BEFORE any network
    // call, so an initiate failure reads as an abandoned checkout rather than
    // as nothing having happened at all.
    _trackCheckoutStarted(
      targetApp != null ? 'upi_app' : 'phonepe_sdk',
      targetApp,
    );

    try {
      // ── Step 1: Initiate payment on the server ───────────────────────────
      // appInstanceId: the debits this mandate produces settle app-closed, so
      // the Worker needs the GA4 join key ON the users row before the first
      // one — login also uploads it, but not for users who signed in on an
      // older build (app_instance_id.dart).
      final appInstanceId = await fetchAppInstanceId();
      // metaAnonId: same reason for the Meta join key — the first trial→paid
      // debit settles app-closed and lib/meta.ts device-matches through it.
      final metaAnonId = await fetchMetaAnonId();
      final initResp = await _initiateWithRetry({
        'plan': 'monthly',
        'appInstanceId': ?appInstanceId,
        'metaAnonId': ?metaAnonId,
        'targetApp': ?targetApp,
      });

      final merchantOrderId = initResp['merchantOrderId'] as String? ?? '';

      // ── Direct UPI-intent flow ───────────────────────────────────────────
      // The server answered with an intentUrl (it falls back to the SDK shape
      // by itself when the intent setup fails, so this branch not running IS
      // the fallback — never re-initiate here, that would hit the claim window).
      final intentUrl = initResp['intentUrl'] as String? ?? '';
      if (intentUrl.isNotEmpty && targetApp != null) {
        if (merchantOrderId.isEmpty) {
          _fail(
            'initiate_incomplete',
            const PurchaseError('Payment initiation failed. Please try again.'),
          );
          return;
        }
        await _startIntentFlow(intentUrl, targetApp, merchantOrderId);
        return;
      }
      final orderId = initResp['orderId'] as String? ?? '';
      final token = initResp['token'] as String? ?? '';
      final merchantId = initResp['merchantId'] as String? ?? '';
      // "SANDBOX" or "PRODUCTION" — forwarded verbatim from the server, which
      // reads it from the PHONEPE_ENV secret and hard-validates it there
      // (workers/src/lib/phonepe.ts isProduction() throws on anything else).
      // Deliberately NO client-side default: a missing value must fail closed.
      // Defaulting to SANDBOX would point a production build at the preprod
      // host, whose 401 is indistinguishable from a bad merchantId — see the
      // symptom map in workers/README.md (PhonePe gotcha 9).
      final environment = initResp['environment'] as String? ?? '';

      if (orderId.isEmpty ||
          token.isEmpty ||
          merchantId.isEmpty ||
          environment.isEmpty) {
        _fail(
          'initiate_incomplete',
          const PurchaseError('Payment initiation failed. Please try again.'),
        );
        return;
      }

      // ── Step 2: Initialise the PhonePe SDK ───────────────────────────────
      // Signature (from developer.phonepe.com/payment-gateway/mobile-app-integration/
      //            standard-checkout-mobile/flutter/sdk-setup):
      //   PhonePePaymentSdk.init(String environment, String merchantId,
      //                          String flowId, bool enableLogging)
      //
      // flowId must be alphanumeric with no special characters.
      // We use the merchantOrderId (server-generated UUID-like value) stripped
      // of hyphens as a per-attempt flow identifier.
      final flowId = merchantOrderId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');

      final sdkInited = await PhonePePaymentSdk.init(
        environment,
        merchantId,
        flowId,
        kDebugMode, // enableLogging — only in debug builds
      );

      if (sdkInited != true) {
        _fail(
          'sdk_init_failed',
          const PurchaseError('PhonePe SDK failed to initialise.'),
        );
        return;
      }

      // ── Step 3: Build the request payload and launch the SDK ─────────────
      // Standard Checkout v2 request format
      // (developer.phonepe.com/payment-gateway/mobile-app-integration/
      //  standard-checkout-mobile/flutter/sdk-setup):
      //
      //   {
      //     "orderId":    <server-returned orderId>,
      //     "merchantId": <server-returned merchantId>,
      //     "token":      <server-returned order token>,
      //     "paymentMode": { "type": "PAY_PAGE" }
      //   }
      //
      // The Flutter SDK expects this JSON-encoded directly as a String.
      // No extra base64 wrapping at the Flutter layer — the server already
      // handles base64 signing internally before returning `token`.
      //
      // NOTE: The official SDK page does NOT document a separate
      // subscription-specific request format for the Flutter SDK; the v2
      // PAY_PAGE flow drives both one-time and recurring mandate setup via
      // the same payload. Confirm with the PhonePe integration team if a
      // dedicated "SUBSCRIPTION" paymentMode key is required for Autopay.
      final request = jsonEncode({
        'orderId': orderId,
        'merchantId': merchantId,
        'token': token,
        'paymentMode': {'type': 'PAY_PAGE'},
      });

      state = const PurchaseProcessing();

      // Signature:
      //   PhonePePaymentSdk.startTransaction(String request, String appSchema)
      // appSchema is iOS-only for the return URL scheme but accepted on Android too.
      final response = await PhonePePaymentSdk.startTransaction(
        request,
        _appSchema,
      );

      if (response == null) {
        // User backed out before the sheet resolved. Release the server's
        // setup claim so an immediate re-tap starts a fresh flow instead of
        // bouncing off 409 setup_in_progress.
        await _abandonSetup(merchantOrderId);
        _fail(
          'user_cancel',
          const PurchaseError('Payment cancelled.', cancelled: true),
        );
        return;
      }

      final sdkStatus = response['status']?.toString() ?? '';
      final sdkError = response['error']?.toString() ?? '';

      if (sdkStatus != 'SUCCESS') {
        // sdkError is a raw SDK payload (e.g. `key_txn_result:
        // {"statusCode":"USER_CANCEL"}`) — never surface it to the user.
        debugPrint('[PremiumPurchase] SDK failure: $sdkStatus $sdkError');
        // Release the server's setup claim so the next tap retries instantly.
        // settled=true means the mandate actually COMPLETED at PhonePe even
        // though the SDK reported a non-success (the stuck-webview class in
        // docs/phonepe.md §Recovery) — confirm through the normal status poll
        // and celebrate; expiring or erroring here would strand a paid mandate.
        final settled = await _abandonSetup(merchantOrderId);
        if (settled) {
          await _confirmWithServer(merchantOrderId);
          return;
        }
        if (sdkError.contains('USER_CANCEL')) {
          _fail(
            'user_cancel',
            const PurchaseError('Payment cancelled.', cancelled: true),
          );
        } else if (sdkStatus == 'INTERRUPTED') {
          _fail(
            'sdk_interrupted',
            const PurchaseError('Payment was interrupted. Please try again.'),
          );
        } else {
          _fail(
            'sdk_failed',
            const PurchaseError('Payment was not completed. Please try again.'),
          );
        }
        return;
      }

      // ── Step 4: Confirm status with the server (short-backoff poll) ───────
      await _confirmWithServer(merchantOrderId);
    } on ApiException catch (e) {
      // The server refuses a second mandate while a live one exists, so this is
      // NOT a failure — it means the user is already subscribed and our local
      // entitlement snapshot was stale (a purchase whose confirmation poll timed
      // out, a reinstall that raced /me, a "Try Again" tap after a success).
      // Treat it as success and re-read entitlement so the UI flips to
      // "Manage Subscription" instead of showing an error for a working account.
      if (e.code == 'already_subscribed') {
        // Invalidate the DETAIL provider — the narrowed entitlementProvider
        // derives from it, so invalidating only the narrow one re-reads the
        // stale cached detail and the UI never flips to "Manage Subscription".
        ref.invalidate(entitlementDetailProvider);
        state = const PurchaseSuccess();
        return;
      }
      // A setup of OUR OWN is still running (double-tap, or a retry after a
      // client timeout whose first attempt is still at PhonePe). Emphatically
      // NOT success: nothing is authorized yet, and reporting success here
      // would flip the UI to "Manage Subscription" for a user with no
      // subscription. Ask them to wait — the in-flight attempt is what will
      // actually settle.
      if (e.code == 'setup_in_progress') {
        _fail(
          'setup_in_progress',
          const PurchaseError(
            'A payment setup is already in progress. '
            'Please wait a few seconds and try again.',
          ),
        );
        return;
      }
      _fail(
        'api_error',
        PurchaseError(
          e.message.isNotEmpty
              ? e.message
              : 'Something went wrong. Please try again.',
        ),
      );
    } catch (e) {
      // Never show the raw exception — it can carry SDK/stack detail.
      debugPrint('[PremiumPurchase] unexpected error: $e');
      _fail(
        'unexpected_error',
        const PurchaseError('Something went wrong. Please try again.'),
      );
    }
  }

  /// Direct UPI-intent flow: launch the chosen UPI app onto its AutoPay sheet
  /// and wait for the server to observe the approval. There is no SDK callback
  /// on this path — the confirmation poll (and the webhook behind it) IS the
  /// completion signal, and [cancelPending] is the user's way out.
  Future<void> _startIntentFlow(
    String intentUrl,
    String targetApp,
    String merchantOrderId,
  ) async {
    final launched = await UpiApps.launch(intentUrl, targetApp);
    if (!launched) {
      // Nothing was authorized (the app never opened) — release the claim so
      // the immediate retry (likely via another UPI app) starts clean.
      await _abandonSetup(merchantOrderId);
      _fail(
        'upi_launch_failed',
        const PurchaseError('Could not open your UPI app. Please try again.'),
      );
      return;
    }

    state = const PurchaseProcessing();
    _intentOrderId = merchantOrderId;
    try {
      await _confirmWithServer(merchantOrderId, delays: _intentPollDelays);
    } finally {
      _intentOrderId = null;
    }
  }

  /// The one failure line the intent flow ever shows. Deliberately the
  /// Shubh-style wording: the audience is not payment-literate, so the app
  /// decides the outcome itself and states the refund hedge plainly — no
  /// "cancelled vs failed vs interrupted" taxonomy, no button they must find.
  static const _intentFailedCopy =
      'Payment failed. Any amount deducted will be '
      'refunded to your account within 4–5 days.';

  /// Guards against overlapping resume checkpoints (rapid backgrounding).
  bool _resolvingIntent = false;

  /// App-resumed checkpoint for the intent flow — the app decides, never the
  /// user. A third-party UPI app (Paytm, GPay…) that the user cancels out of
  /// tells PhonePe NOTHING — the order just stays PENDING — so the user
  /// returning to Arul is itself the signal:
  ///
  ///   1. Check the server immediately (an approval settles here).
  ///   2. Still open → one short grace poll (settlement can lag approval by
  ///      a few seconds).
  ///   3. STILL open → declare the payment failed ourselves: release the
  ///      claim (order-status-guarded — a payment that actually settled is
  ///      granted, never discarded) and show the refund line.
  ///
  /// The residual race — approval landing AFTER the auto-release — is closed
  /// server-side: the setup webhook resurrects an abandon-expired claim, so a
  /// paid mandate always grants even if this screen already said failed.
  Future<void> pollNowOnResume() async {
    final orderId = _intentOrderId;
    if (orderId == null || state is! PurchaseProcessing || _resolvingIntent) {
      return;
    }
    _resolvingIntent = true;
    try {
      if (await _settleFromStatus(orderId)) return;
      // Short grace only — the popup must feel immediate. An approval that
      // settles later than this is still never lost: the abandon below checks
      // the live order state first, and the setup webhook resurrects an
      // abandon-raced approval server-side.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (state is! PurchaseProcessing) return;
      if (await _settleFromStatus(orderId)) return;
      if (state is! PurchaseProcessing) return;
      await _autoResolveIntent(orderId);
    } finally {
      _resolvingIntent = false;
    }
  }

  /// One status check. Returns true when it OWNED the outcome (granted or
  /// failed); false when the order is still open and the caller decides.
  Future<bool> _settleFromStatus(String orderId) async {
    try {
      final statusResp = await _api.post('/payments/status');
      final serverStatus = statusResp['status'] as String? ?? '';
      if (state is! PurchaseProcessing) return true; // someone else settled it

      if (serverStatus == 'trialing' || serverStatus == 'active') {
        _pollGeneration++;
        _trackConversion(
          serverStatus == 'trialing' ? 'trial_started' : 'subscription_active',
          orderId,
        );
        ref.invalidate(entitlementDetailProvider);
        state = const PurchaseSuccess();
        return true;
      }
      if (serverStatus == 'expired') {
        _pollGeneration++;
        _fail('expired', const PurchaseError(_intentFailedCopy));
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[PremiumPurchase] resume status check failed: $e');
      return false;
    }
  }

  /// Declares the intent-flow payment failed on the user's behalf: silences
  /// the background poll, releases the claim (settled-guarded), shows the
  /// refund line. The abandoned mandate can never debit — it was never
  /// authorized, and the next initiate supersedes + revokes it regardless.
  Future<void> _autoResolveIntent(String orderId) async {
    _pollGeneration++;
    final settled = await _abandonSetup(orderId);
    if (settled) {
      await _confirmWithServer(orderId);
      return;
    }
    _fail('intent_abandoned', const PurchaseError(_intentFailedCopy));
  }

  /// Steps 4+5: short-backoff poll of /payments/status until the server
  /// confirms the mandate (its reconcile grants even when the webhook is
  /// lost), then fire the ★ conversion event and flip to [PurchaseSuccess].
  /// Sets a terminal [PurchaseError] when the server reports a dead state or
  /// the poll budget runs out. Goes silent (no state writes) if
  /// [_pollGeneration] moves — a cancel owns the state from that moment.
  ///
  /// trialing → StartTrial, active → Subscribe. Both carry the monthly price
  /// (INR) + PhonePe merchant order id so Meta can optimise for ROAS and
  /// dedupe. PostHog gets the same event via the composite.
  Future<void> _confirmWithServer(
    String merchantOrderId, {
    List<int> delays = _sdkPollDelays,
  }) async {
    final generation = _pollGeneration;

    // Did ANY attempt actually get an answer out of the server? A poll that
    // never reached it knows nothing about the mandate, so the give-up branch
    // below must not claim the payment failed.
    var reachedServer = false;

    for (final delay in delays) {
      await Future<void>.delayed(Duration(seconds: delay));
      if (generation != _pollGeneration) return;

      try {
        final statusResp = await _api.post('/payments/status');
        reachedServer = true;
        final serverStatus = statusResp['status'] as String? ?? '';
        if (generation != _pollGeneration) return;

        if (serverStatus == 'trialing' || serverStatus == 'active') {
          _trackConversion(
            serverStatus == 'trialing'
                ? 'trial_started'
                : 'subscription_active',
            merchantOrderId,
          );
          ref.invalidate(entitlementDetailProvider);
          state = const PurchaseSuccess();
          return;
        }

        // If still pending, keep polling.
        if (serverStatus == 'pending') continue;

        // 'expired' during a setup poll = the setup died at the UPI app. On
        // the intent flow show the one standard failure+refund line (the app
        // decides — see _intentFailedCopy); on the SDK flow the user already
        // saw PhonePe's own screens, so a neutral cancelled toast fits.
        if (serverStatus == 'expired') {
          _fail(
            'expired',
            _intentOrderId != null
                ? const PurchaseError(_intentFailedCopy)
                : const PurchaseError('Payment cancelled.', cancelled: true),
          );
          return;
        }

        // Any other terminal state (cancelled etc.) = failure.
        debugPrint('[PremiumPurchase] terminal server status: $serverStatus');
        _fail(
          'server_terminal',
          const PurchaseError(
            'We couldn’t activate your subscription. Please contact support.',
          ),
        );
        return;
      } on ApiException catch (e) {
        // 404 means no subscription yet — keep polling.
        if (e.status == 404) continue;
        rethrow;
      } catch (e) {
        // A transient network failure is the NORMAL case here, not an error:
        // the app is backgrounded behind the UPI app and Android tears the
        // radio down, so a poll routinely dies on
        // `SocketException: Failed host lookup` mid-flow. This used to rethrow
        // — one blip abandoned the whole remaining budget, surfaced
        // "Something went wrong", and (via the finally in _startIntentFlow)
        // nulled _intentOrderId so pollNowOnResume bailed too. The mandate
        // then settled at PhonePe with nobody watching and the user got no
        // premium. Reproduced on device 2026-08-11.
        debugPrint('[PremiumPurchase] poll attempt failed, retrying: $e');
        continue;
      }
    }

    if (generation != _pollGeneration) return;

    // Every attempt died before reaching the server, so we know NOTHING about
    // this mandate — the user may well have approved it. Neither the refund
    // line nor an abandon is honest on that evidence (and the abandon call
    // would fail on the same dead network anyway, leaving the claim to lapse
    // on its own). Say confirmation is late: the setup webhook still grants
    // server-side and the paywall's pending self-heal picks it up on reopen.
    if (!reachedServer) {
      // NOT a known failure: the mandate may well have been approved. Still
      // counted, because the user's checkout ended without premium — the
      // `reason` is what separates it from a real declination.
      _fail(
        'confirmation_unreachable',
        const PurchaseError(
          'Payment received but confirmation is delayed. '
          'Please restart the app — your subscription will activate shortly.',
        ),
      );
      return;
    }

    // Exhausted retries — server hasn't confirmed yet. Intent flow: the user
    // most likely dismissed a third-party UPI app that told no one — resolve
    // it FOR them (settled-guarded release + the refund line), same as the
    // resume checkpoint. SDK flow: a SUCCESS callback fired, so a payment
    // definitely happened and only confirmation is late — say so.
    final intentOrderId = _intentOrderId;
    if (intentOrderId != null) {
      await _autoResolveIntent(intentOrderId);
      return;
    }
    _fail(
      'confirmation_late',
      const PurchaseError(
        'Payment received but confirmation is delayed. '
        'Please restart the app — your subscription will activate shortly.',
      ),
    );
  }

  /// POST /payments/initiate, riding out 409 `setup_in_progress` silently.
  ///
  /// That 409 means our own previous attempt's claim is still inside the
  /// server's short backstop window — almost always a rapid re-tap right after
  /// backing out, racing the abandon call that releases the claim. A
  /// human-visible "please wait and try again" for a wait measured in seconds
  /// reads as "payments broken" (the 90 s lockout taught that), so ride it out
  /// under the spinner instead.
  ///
  /// The delays are PAIRED with SETUP_CLAIM_WINDOW_MS (4 s) server-side: they
  /// SUM past it, so by the last retry any claim born before this call has
  /// provably lapsed and the only 409 that can survive is a genuinely
  /// concurrent attempt — which is exactly the one that must refuse (the
  /// double-mandate guard is untouched; every retry is a normal initiate,
  /// serialized server-side like any other). Change the window and these
  /// delays together, keeping sum(delays) >= window.
  static const _initiateRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 2),
  ];

  Future<dynamic> _initiateWithRetry(Map<String, Object?> body) async {
    for (final delay in _initiateRetryDelays) {
      try {
        return await _api.post('/payments/initiate', body: body);
      } on ApiException catch (e) {
        if (e.code != 'setup_in_progress') rethrow;
        await Future<void>.delayed(delay);
      }
    }
    return _api.post('/payments/initiate', body: body);
  }

  /// Tells the server the launched setup is dead so its claim is released and
  /// the very next initiate starts fresh (no 409 wait-out). Returns true when
  /// the server reports the mandate actually settled at PhonePe — the caller
  /// must then confirm via [_confirmWithServer] instead of showing an error.
  /// Best-effort: on any failure returns false and the claim simply lapses
  /// server-side after its short window.
  Future<bool> _abandonSetup(String merchantOrderId) async {
    try {
      final resp = await _api.post(
        '/payments/abandon',
        body: {'merchantOrderId': merchantOrderId},
      );
      return resp['settled'] == true;
    } catch (e) {
      debugPrint('[PremiumPurchase] abandon failed: $e');
      return false;
    }
  }

  /// Resets the state back to idle (e.g. to dismiss an error and allow retry).
  void reset() {
    state = const PurchaseIdle();
  }

  /// Reconciles subscription state with the server, then refreshes entitlement
  /// so the UI reflects the true, current state.
  ///
  /// Hitting /payments/status lets the Worker detect a mandate the user revoked
  /// directly in their PhonePe/UPI app — those bank-initiated revokes usually
  /// fire no merchant webhook, so our row can otherwise stay stale as
  /// `active`/`trialing`. Safe to call on the Manage screen open and after any
  /// cancel attempt (success OR failure), so state never drifts from the server.
  Future<void> refreshStatus() async {
    try {
      await _api.post('/payments/status');
    } catch (_) {
      // Non-fatal: fall back to whatever /me/subscription returns on invalidate.
    }
    ref.invalidate(entitlementDetailProvider);
  }

  /// Cancels the active subscription (revokes the PhonePe mandate).
  ///
  /// Calls POST /payments/cancel. The user keeps premium until the current
  /// period ends — the server stops future debits but does not strip
  /// entitlement. Returns null on success, or an error message to display.
  ///
  /// Kept separate from the [PurchaseState] machine: the caller (Manage
  /// Subscription) drives its own confirm dialog + snackbar.
  Future<String?> cancel() async {
    try {
      await _api.post('/payments/cancel');
      // Refresh entitlement so any UI bound to it re-reads the new state.
      ref.invalidate(entitlementDetailProvider);
      return null;
    } on ApiException catch (e) {
      return e.message.isNotEmpty
          ? e.message
          : 'Could not cancel your subscription. Please try again.';
    } catch (e) {
      debugPrint('[PremiumPurchase] cancel failed: $e');
      return 'Something went wrong. Please try again.';
    }
  }
}
