import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../data/models/subscription_model.dart';
import '../domain/entitlement.dart';
import '../domain/subscription_repository.dart';

class ApiSubscriptionRepository implements SubscriptionRepository {
  const ApiSubscriptionRepository({required ApiClient apiClient})
    : _api = apiClient;

  final ApiClient _api;

  @override
  Future<Entitlement> getEntitlement(String userId) async {
    // `premium` is the Worker-computed flag and the ONLY source of the decision (see Entitlement) ->
    // strict `== true` fails CLOSED to free -> the Worker's /media/signed-url stays the real gate.
    try {
      final data = await _api.get('/me');
      final sub = data['subscription'] as Map<String, dynamic>?;
      return Entitlement(
        isPremium: data['premium'] == true,
        subscription: sub == null ? null : SubscriptionModel.fromJson(sub),
      );
    } on ApiException catch (e) {
      // 404 = the users row is gone (deleted on another device while this access token was live) ->
      // degrade to free, never error.
      if (e.status == 404) return const Entitlement.none();
      rethrow;
    }
  }

  @override
  Future<void> notePaywallView(
    String source,
    Map<String, Object> context,
  ) async {
    try {
      await _api.post(
        '/me/paywall-view',
        body: {'source': source, 'context': context},
      );
    } catch (e) {
      // Analytics only -> a lost view is a missing row, never an error on the paywall.
      debugPrint('[Paywall] view not recorded: $e');
    }
  }

  @override
  Future<void> notePaywallExit(String source, String exit, int dwellS) async {
    try {
      await _api.post(
        '/me/paywall-view',
        body: {'source': source, 'exit': exit, 'dwell_s': dwellS},
      );
    } catch (e) {
      debugPrint('[Paywall] exit not recorded: $e');
    }
  }
}
