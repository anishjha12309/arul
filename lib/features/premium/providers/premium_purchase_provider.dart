import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:phonepe_payment_sdk/phonepe_payment_sdk.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/api/api_client.dart';
import '../../../core/upi/upi_apps.dart';
import 'entitlement_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../features/auth/providers/auth_providers.dart';
import 'trial_conversion_catch_up.dart';

part 'premium_purchase_provider.g.dart';

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

  /// True when the user backed out of PhonePe themselves -> a neutral toast, never a red failure.
  final bool cancelled;
}

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
  PurchaseState build() {
    // Captured while the ref is ALIVE, on purpose.
    // This notifier is autoDispose, but a checkout keeps running after the paywall is popped.
    // Every `ref.read` in that continuation threw "Cannot use the Ref after it has been disposed".
    // The throw landed BEFORE `trial_started` was tracked -> a late mandate reached Neon and no sink.
    // Holding the dependencies here -> the poll finishes on a dead ref, only UI writes are skipped.
    _api = ref.read(apiClientProvider);
    _analytics = ref.read(analyticsServiceProvider);
    _catchUp = ref.read(trialConversionCatchUpProvider);
    return const PurchaseIdle();
  }

  late ApiClient _api;
  late AnalyticsService _analytics;
  late TrialConversionCatchUp _catchUp;

  /// Writes [next] only while the paywall still owns this notifier.
  /// After the pop the state has no reader and the setter throws -> the write is dropped.
  /// The next paywall open reconciles from the server.
  void _setState(PurchaseState next) {
    if (ref.mounted) state = next;
  }

  /// A checkout still awaiting its outcome AND someone there to see it.
  /// False once disposed -> in-flight work then only reports events, never repaints.
  bool get _isProcessing => ref.mounted && state is PurchaseProcessing;

  /// Re-reads entitlement so the UI flips — skipped when disposed; the open-time reconcile covers it.
  void _refreshEntitlement() {
    if (ref.mounted) ref.invalidate(entitlementDetailProvider);
  }

  /// Tracks a ★ conversion event with the monthly price and order id.
  ///
  /// Fans out to PostHog, GA4 and Meta via the composite; a missing price just omits the value.
  /// A `trial_started` is then MARKED reported — AFTER the track, so nothing precedes the event.
  /// And BEFORE every caller's invalidate -> the refresh cannot fire [TrialConversionCatchUp]'s copy.
  void _trackConversion(String event, String merchantOrderId) {
    // A poll that outlived the paywall can settle after the catch-up already fired the late copy.
    // The marker is the one record that this order's `trial_started` went out -> consult it first.
    if (event == ArulEvents.trialStarted &&
        _catchUp.isReported(merchantOrderId)) {
      return;
    }
    final price = _monthlyPriceRupees();
    _analytics.track(
      event,
      properties: {
        'plan': 'monthly',
        'order_id': merchantOrderId,
        // Null-aware element: omitted entirely when the price hasn't loaded.
        'value': ?price,
      },
    );
    if (event == ArulEvents.trialStarted) {
      _catchUp.markReported(merchantOrderId);
    }
  }

  /// Fires `checkout_started` the moment the user commits — BEFORE /payments/initiate.
  ///
  /// So a server-side initiate failure still reads as an abandoned checkout rather than vanishing.
  /// This is the funnel's missing middle; without it the UPI-handoff loss had to be rebuilt by hand.
  /// GA4 maps it to `begin_checkout` and Meta to InitiateCheckout -> both optimisers see the top.
  /// [method] records which handoff was ATTEMPTED, not which ran — the server may fall back itself.
  /// `target_app` is the UPI package — the axis that makes "which app expires a mandate" answerable.
  void _trackCheckoutStarted(String method, String? targetApp) {
    _checkoutMethod = method;
    final price = _monthlyPriceRupees();
    _analytics.track(
      'checkout_started',
      properties: {
        'plan': 'monthly',
        'method': method,
        'target_app': ?targetApp,
        'value': ?price,
      },
    );
  }

  /// The ONE terminal-failure event, emitted through [_fail] -> no error path can skip it.
  ///
  /// GA4-only by construction: off the PostHog allow-list, and Meta drops non-conversions.
  /// A failure is a diagnostic -> feeding it to an ad optimiser trains the wrong thing.
  /// [reason] is a short STABLE code, NEVER the user-facing copy — prose would fragment the metric.
  /// `cancelled` separates a deliberate back-out from a real failure, as `login_cancelled` does.
  void _trackPaymentFailed(String reason, {required bool cancelled}) {
    _analytics.track(
      'payment_failed',
      properties: {
        'reason': reason,
        'cancelled': cancelled,
        'plan': 'monthly',
        // Which handoff was in flight when it died — the whole point of the event.
        // Null only if a failure somehow precedes the tap.
        'method': ?_checkoutMethod,
      },
    );
  }

  /// Terminal failure — set the error state AND report it, in that order, counted exactly once.
  /// Always prefer this over assigning [PurchaseError] directly.
  void _fail(String reason, PurchaseError error) {
    _setState(error);
    _trackPaymentFailed(reason, cancelled: error.cancelled);
  }

  /// Ends the flow WITHOUT a confirmed answer — the mandate may well be live.
  /// Identical to [_fail] plus an entitlement re-read.
  ///
  /// The grant can land while this screen is giving up — a dead radio, or a spent poll budget.
  /// Without the re-read the paywall keeps its stale snapshot and offers a trial to a payer.
  /// An owner test then concluded the payment had failed and revoked a LIVE mandate from their app.
  /// The refresh makes the screen self-correct as soon as `/me` says premium.
  void _failUnconfirmed(String reason, PurchaseError error) {
    _fail(reason, error);
    _refreshEntitlement();
  }

  /// The checkout handoff in flight (`upi_app`/`phonepe_sdk`), set at start and read on failure.
  /// So a failure names the path that died. Survives for the attempt's lifetime.
  String? _checkoutMethod;

  /// Monthly price in rupees from the remote app_config; null until it loads.
  /// Read synchronously from the already-cached provider -> no await on the success path.
  double? _monthlyPriceRupees() => ref.mounted
      ? monthlyPriceRupees(ref.read(appConfigProvider).asData?.value) ??
            _priceAtStart
      : _priceAtStart;

  /// Price captured at the TAP -> a conversion reported after the paywall is gone still has a value.
  double? _priceAtStart;

  /// Deep-link return scheme registered in AndroidManifest.xml.
  /// PhonePe uses this to bring the app back to the foreground after payment.
  static const _appSchema = 'arul';

  /// SDK-path confirmation poll — the callback already said SUCCESS, so the reconcile is seconds away.
  static const _sdkPollDelays = [1, 2, 3, 5, 8];

  /// Intent-path confirmation poll — the user is entering a PIN; approval routinely takes a minute.
  /// ~2 minutes before giving up; the webhook still grants later, and reopening self-heals.
  static const _intentPollDelays = [
    4, 4, 4, 5, 5, 6, 8, 8, 10, 10, 10, 10, 10, 10, 10, 10, //
  ];

  /// The merchant order id of an intent setup awaiting UPI approval — [cancelPending]'s handle.
  /// Null outside that window.
  String? _intentOrderId;

  /// Bumped to cancel a running [_confirmWithServer] loop — it captures the value and goes silent.
  /// So a user-tapped cancel owns the next state without racing a late poll response.
  int _pollGeneration = 0;

  /// Starts the 1-day free trial via PhonePe.
  ///
  /// [targetApp] selects the direct UPI-intent flow — that app opens onto its AutoPay sheet.
  /// Null → the PhonePe SDK hosted-page flow.
  Future<void> startTrial({String? targetApp}) async {
    if (state is PurchaseLoading || state is PurchaseProcessing) return;

    state = const PurchaseLoading();
    _priceAtStart = _monthlyPriceRupees();
    // The user has committed -> count the checkout BEFORE any network call.
    // So an initiate failure reads as an abandoned checkout, not as nothing having happened.
    _trackCheckoutStarted(
      targetApp != null ? 'upi_app' : 'phonepe_sdk',
      targetApp,
    );

    try {
      // Step 1: initiate payment on the server.
      final initResp = await _initiateWithRetry({
        'plan': 'monthly',
        'targetApp': ?targetApp,
      });

      final merchantOrderId = initResp['merchantOrderId'] as String? ?? '';

      // Direct UPI-intent flow: the server answered with an intentUrl.
      // It falls back to the SDK shape itself -> this branch not running IS the fallback.
      // NEVER re-initiate here — that would hit the claim window.
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
      // "SANDBOX" or "PRODUCTION", forwarded verbatim from the server, which hard-validates it.
      // Deliberately NO client-side default — a missing value must fail CLOSED.
      // Defaulting to SANDBOX points a production build at preprod, whose 401 looks like a bad id.
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

      // Step 2: initialise the PhonePe SDK.
      //   PhonePePaymentSdk.init(String environment, String merchantId, String flowId, bool logging)
      // flowId must be ALPHANUMERIC with no special characters.
      // So the merchantOrderId, hyphens stripped, is the per-attempt flow identifier.
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

      // Step 3: build the Standard Checkout v2 payload and launch the SDK.
      //   { orderId, merchantId, token, paymentMode: { type: "PAY_PAGE" } }
      // The Flutter SDK expects this JSON-encoded directly as a String.
      // NO extra base64 wrapping here — the server signs before returning `token`.
      // The SDK page documents no subscription-specific format; v2 PAY_PAGE drives both flows.
      final request = jsonEncode({
        'orderId': orderId,
        'merchantId': merchantId,
        'token': token,
        'paymentMode': {'type': 'PAY_PAGE'},
      });

      _setState(const PurchaseProcessing());

      // Signature:
      //   PhonePePaymentSdk.startTransaction(String request, String appSchema)
      // appSchema is iOS-only for the return URL scheme but accepted on Android too.
      final response = await PhonePePaymentSdk.startTransaction(
        request,
        _appSchema,
      );

      if (response == null) {
        // User backed out before the sheet resolved -> release the server's setup claim.
        // So an immediate re-tap starts a fresh flow instead of bouncing off 409 setup_in_progress.
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
        // sdkError is a raw SDK payload — NEVER surface it to the user.
        debugPrint('[PremiumPurchase] SDK failure: $sdkStatus $sdkError');
        // Release the server's setup claim so the next tap retries instantly.
        // settled=true means the mandate COMPLETED at PhonePe despite the SDK's non-success.
        // So confirm through the normal poll — expiring or erroring here strands a PAID mandate.
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

      // Step 4: confirm status with the server, on a short-backoff poll.
      await _confirmWithServer(merchantOrderId);
    } on ApiException catch (e) {
      // The server refuses a second mandate while a live one exists -> NOT a failure.
      // It means the user is already subscribed and our entitlement snapshot was stale.
      // So treat it as success and re-read -> the UI flips to Manage, not an error on a live account.
      if (e.code == 'already_subscribed') {
        // The narrowed entitlementProvider DERIVES from the detail one.
        // Invalidating only the narrow one re-reads the stale detail -> the UI never flips.
        _refreshEntitlement();
        _setState(const PurchaseSuccess());
        return;
      }
      // A setup of OUR OWN is still running — a double-tap, or a retry over a live first attempt.
      // Emphatically NOT success: nothing is authorized, and claiming it would flip the UI wrongly.
      // Ask them to wait — the in-flight attempt is what will actually settle.
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
      // Never show the raw exception — it can carry SDK or stack detail.
      debugPrint('[PremiumPurchase] unexpected error: $e');
      _fail(
        'unexpected_error',
        const PurchaseError('Something went wrong. Please try again.'),
      );
    }
  }

  /// Direct UPI-intent flow — launch the chosen app onto its AutoPay sheet, then watch the server.
  /// There is NO SDK callback here -> the confirmation poll, and the webhook behind it, is the signal.
  /// [cancelPending] is the user's way out.
  Future<void> _startIntentFlow(
    String intentUrl,
    String targetApp,
    String merchantOrderId,
  ) async {
    final launched = await UpiApps.launch(intentUrl, targetApp);
    if (!launched) {
      // Nothing was authorized — the app never opened -> release the claim so a retry starts clean.
      await _abandonSetup(merchantOrderId);
      _fail(
        'upi_launch_failed',
        const PurchaseError('Could not open your UPI app. Please try again.'),
      );
      return;
    }

    _setState(const PurchaseProcessing());
    _intentOrderId = merchantOrderId;
    try {
      await _confirmWithServer(merchantOrderId, delays: _intentPollDelays);
    } finally {
      _intentOrderId = null;
    }
  }

  /// The ONE failure line the intent flow ever shows.
  /// The audience is not payment-literate -> the app decides, and states the refund hedge plainly.
  /// No "cancelled vs failed vs interrupted" taxonomy, and no button they must find.
  static const _intentFailedCopy =
      'Payment failed. Any amount deducted will be '
      'refunded to your account within 4–5 days.';

  /// Guards against overlapping resume checkpoints (rapid backgrounding).
  bool _resolvingIntent = false;

  /// App-resumed checkpoint for the intent flow — the APP decides, never the user.
  ///
  /// A third-party UPI app the user cancels out of tells PhonePe NOTHING; the order stays PENDING.
  /// So the user returning to Arul is itself the signal:
  ///
  ///   1. check the server immediately — an approval settles here;
  ///   2. still open → one short grace poll, since settlement can lag approval by seconds;
  ///   3. STILL open → declare it failed: release the claim, order-status-guarded, and show the line.
  ///
  /// A settled payment is granted, never discarded.
  /// The residual race — approval landing AFTER the release — is closed by the setup webhook.
  Future<void> pollNowOnResume() async {
    final orderId = _intentOrderId;
    if (orderId == null || !_isProcessing || _resolvingIntent) {
      return;
    }
    _resolvingIntent = true;
    try {
      if (await _settleFromStatus(orderId)) return;
      // NO artificial delay. Production tails showed PhonePe still PENDING at both samples of a
      // 2 s re-poll on every real back-out -> the wait never changed an outcome, only held a spinner.
      // Redundant by construction too: the abandon below re-reads the LIVE order and answers
      // settled:true when PhonePe says COMPLETED, from a strictly fresher read than a second poll.
      // Anything later than that belongs to the setup webhook. Resolution is now network-bound.
      if (!_isProcessing) return;
      await _autoResolveIntent(orderId);
    } finally {
      _resolvingIntent = false;
    }
  }

  /// One status check — true when it OWNED the outcome, false when the order is still open.
  Future<bool> _settleFromStatus(String orderId) async {
    try {
      final statusResp = await _api.post('/payments/status');
      final serverStatus = statusResp['status'] as String? ?? '';
      // A cancel owned the outcome meanwhile.
      // A DISPOSED notifier is not that case — nothing else can settle its order — so it reports.
      if (ref.mounted && state is! PurchaseProcessing) return true;

      if (serverStatus == 'trialing' || serverStatus == 'active') {
        _pollGeneration++;
        _trackConversion(
          serverStatus == 'trialing'
              ? ArulEvents.trialStarted
              : ArulEvents.subscriptionActive,
          orderId,
        );
        _refreshEntitlement();
        _setState(const PurchaseSuccess());
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

  /// Declares the intent payment failed for the user — silence the poll, release the claim, show it.
  /// The abandoned mandate can never debit: it was never authorized, and the next initiate revokes it.
  Future<void> _autoResolveIntent(String orderId) async {
    _pollGeneration++;
    final settled = await _abandonSetup(orderId);
    if (settled) {
      await _confirmWithServer(orderId);
      return;
    }
    _fail('intent_abandoned', const PurchaseError(_intentFailedCopy));
  }

  /// Short-backoff poll of /payments/status until the server confirms the mandate.
  ///
  /// Its reconcile grants even when the webhook is lost -> then fire ★ and flip to [PurchaseSuccess].
  /// A dead server state, or a spent poll budget, sets a terminal [PurchaseError].
  /// Goes SILENT if [_pollGeneration] moves — a cancel owns the state from that moment.
  /// Both events carry the monthly price (INR) and the merchant order id, for ROAS and dedup.
  Future<void> _confirmWithServer(
    String merchantOrderId, {
    List<int> delays = _sdkPollDelays,
  }) async {
    final generation = _pollGeneration;

    // Did ANY attempt get an answer out of the server?
    // A poll that never reached it knows nothing -> the give-up branch must not claim failure.
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
                ? ArulEvents.trialStarted
                : ArulEvents.subscriptionActive,
            merchantOrderId,
          );
          _refreshEntitlement();
          _setState(const PurchaseSuccess());
          return;
        }

        // If still pending, keep polling.
        if (serverStatus == 'pending') continue;

        // 'expired' during a setup poll = the setup died at the UPI app.
        // Intent flow -> the one standard failure+refund line, because the app decides.
        // SDK flow -> the user already saw PhonePe's own screens, so a neutral toast fits.
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
        // A transient network failure is the NORMAL case here, not an error.
        // Android tears the radio down behind the UPI app -> a poll routinely dies mid-flow.
        // Rethrowing abandoned the whole remaining budget and nulled `_intentOrderId`.
        // pollNowOnResume then bailed too, the mandate settled unwatched, and the user got nothing.
        debugPrint('[PremiumPurchase] poll attempt failed, retrying: $e');
        continue;
      }
    }

    if (generation != _pollGeneration) return;

    // Every attempt died before reaching the server -> we know NOTHING about this mandate.
    // Neither the refund line nor an abandon is honest on that evidence.
    // The abandon would fail on the same dead network anyway, leaving the claim to lapse.
    // So say confirmation is LATE — the setup webhook still grants, and reopening self-heals.
    if (!reachedServer) {
      // NOT a known failure — the mandate may well have been approved.
      // Still counted, because the checkout ended without premium; `reason` separates the two.
      _failUnconfirmed(
        'confirmation_unreachable',
        const PurchaseError(
          'Payment received but confirmation is delayed. '
          'Please restart the app — your subscription will activate shortly.',
        ),
      );
      return;
    }

    // Retries exhausted and the server has not confirmed.
    // Intent flow -> most likely a dismissed third-party app that told no one, so resolve it FOR them.
    // SDK flow -> a SUCCESS callback fired, so a payment happened and only confirmation is late.
    final intentOrderId = _intentOrderId;
    if (intentOrderId != null) {
      await _autoResolveIntent(intentOrderId);
      return;
    }
    _failUnconfirmed(
      'confirmation_late',
      const PurchaseError(
        'Payment received but confirmation is delayed. '
        'Please restart the app — your subscription will activate shortly.',
      ),
    );
  }

  /// POST /payments/initiate, riding out 409 `setup_in_progress` silently.
  ///
  /// That 409 means our own previous claim is still inside the server's short backstop window.
  /// Almost always a rapid re-tap racing the abandon call that releases the claim.
  /// "Please wait and try again" for a wait measured in seconds reads as "payments broken".
  /// So ride it out under the spinner instead.
  /// The delays are PAIRED with SETUP_CLAIM_WINDOW_MS server-side and SUM past it.
  /// So by the last retry any older claim has provably lapsed, and only a concurrent attempt 409s.
  /// That one must refuse — the double-mandate guard is untouched.
  /// Change the window and these delays together, keeping sum(delays) >= window.
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

  /// Tells the server the launched setup is dead -> the claim is released and the next initiate is clean.
  /// True when the server reports the mandate actually SETTLED at PhonePe.
  /// The caller must then confirm via [_confirmWithServer] instead of showing an error.
  /// Best-effort — any failure returns false and the claim simply lapses after its short window.
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

  /// Reconciles subscription state with the server, then refreshes entitlement.
  ///
  /// A mandate revoked inside the user's UPI app fires no merchant webhook.
  /// So our row can stay stale as `active`/`trialing` -> hitting /payments/status is what detects it.
  /// Safe on the Manage screen open and after any cancel attempt, success or failure.
  Future<void> refreshStatus() async {
    try {
      await _api.post('/payments/status');
    } catch (_) {
      // Non-fatal — fall back to whatever the invalidate re-reads.
    }
    _refreshEntitlement();
  }

  /// Cancels the active subscription (revokes the PhonePe mandate).
  ///
  /// Calls POST /payments/cancel — the server stops future debits but does NOT strip entitlement.
  /// The user keeps premium until the current period ends.
  /// Returns null on success, or an error message to display.
  /// Kept OFF the [PurchaseState] machine — the caller drives its own confirm dialog and snackbar.
  Future<String?> cancel() async {
    try {
      await _api.post('/payments/cancel');
      // Refresh entitlement so any UI bound to it re-reads the new state.
      _refreshEntitlement();
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
