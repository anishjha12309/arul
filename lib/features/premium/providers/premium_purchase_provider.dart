import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:phonepe_payment_sdk/phonepe_payment_sdk.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/api/api_client.dart';
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
  const PurchaseError(this.message);
  final String message;
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

  // ── Public API ────────────────────────────────────────────────────────────

  /// Starts the 1-day free trial via PhonePe Standard Checkout v2.
  Future<void> startTrial() async {
    if (state is PurchaseLoading || state is PurchaseProcessing) return;

    state = const PurchaseLoading();

    try {
      // ── Step 1: Initiate payment on the server ───────────────────────────
      final initResp = await _api.post(
        '/payments/initiate',
        body: {'plan': 'monthly'},
      );

      final merchantOrderId = initResp['merchantOrderId'] as String? ?? '';
      final orderId = initResp['orderId'] as String? ?? '';
      final token = initResp['token'] as String? ?? '';
      final merchantId = initResp['merchantId'] as String? ?? '';
      // "SANDBOX" or "PRODUCTION" — forwarded verbatim from the server.
      final environment = (initResp['environment'] as String?) ?? 'SANDBOX';

      if (orderId.isEmpty || token.isEmpty || merchantId.isEmpty) {
        state = const PurchaseError(
          'Payment initiation failed. Please try again.',
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
        state = const PurchaseError('PhonePe SDK failed to initialise.');
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
        state = const PurchaseError('Payment was cancelled.');
        return;
      }

      final sdkStatus = response['status']?.toString() ?? '';
      final sdkError = response['error']?.toString() ?? '';

      if (sdkStatus == 'INTERRUPTED') {
        state = const PurchaseError(
          'Payment was interrupted. Please try again.',
        );
        return;
      }

      if (sdkStatus != 'SUCCESS') {
        final msg = sdkError.isNotEmpty
            ? 'Payment failed: $sdkError'
            : 'Payment was not completed. Please try again.';
        state = PurchaseError(msg);
        return;
      }

      // ── Step 4: Confirm status with the server (short-backoff poll) ───────
      const maxAttempts = 5;
      const delays = [1, 2, 3, 5, 8]; // seconds

      for (var i = 0; i < maxAttempts; i++) {
        await Future<void>.delayed(Duration(seconds: delays[i]));

        try {
          final statusResp = await _api.post('/payments/status');
          final serverStatus = statusResp['status'] as String? ?? '';

          if (serverStatus == 'trialing' || serverStatus == 'active') {
            // ── Step 5: Fire the ★ conversion event, then refresh ───────────
            // trialing → StartTrial, active → Subscribe. Both carry the monthly
            // price (INR) + PhonePe merchant order id so Meta can optimise for
            // ROAS and dedupe. PostHog gets the same event via the composite.
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

          // Any other terminal state (cancelled, expired, etc.) = failure.
          state = PurchaseError(
            'Subscription status: $serverStatus. Please contact support.',
          );
          return;
        } on ApiException catch (e) {
          // 404 means no subscription yet — keep polling.
          if (e.status == 404) continue;
          rethrow;
        }
      }

      // Exhausted retries — server hasn't confirmed yet.
      state = const PurchaseError(
        'Payment received but confirmation is delayed. '
        'Please restart the app — your subscription will activate shortly.',
      );
    } on ApiException catch (e) {
      state = PurchaseError(
        e.message.isNotEmpty
            ? e.message
            : 'Something went wrong. Please try again.',
      );
    } catch (e) {
      state = PurchaseError('Unexpected error: $e');
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
      return 'Unexpected error: $e';
    }
  }
}
