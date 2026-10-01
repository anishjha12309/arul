import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 1, 12);

  SubscriptionModel pending({
    required bool offerSwitch,
    DateTime? trialEnd,
    Duration left = const Duration(hours: 20),
  }) => SubscriptionModel(
    id: 's',
    userId: 'u',
    status: SubscriptionStatus.pending,
    currentPeriodEnd: now.add(left),
    trialEnd: trialEnd,
    offerSwitch: offerSwitch,
    pricePaise: offerSwitch ? 9900 : 19900,
  );

  test(
    'a ₹199 claim over a live period is the cancelled plan it resubscribes',
    () {
      expect(
        pending(offerSwitch: false).shownStatus(now),
        SubscriptionStatus.cancelled,
      );
    },
  );

  test(
    'a ₹99 winback in flight is still the cancelled plan it comes back from',
    () {
      final winback = SubscriptionModel(
        id: 's',
        userId: 'u',
        status: SubscriptionStatus.pending,
        currentPeriodEnd: now.add(const Duration(days: 3)),
        trialEnd: now.subtract(const Duration(days: 30)),
        pricePaise: 9900,
      );
      expect(winback.shownStatus(now), SubscriptionStatus.cancelled);
    },
  );

  test(
    'a ₹99 switch shows the plan it left: a trial while the period is the trial',
    () {
      final end = now.add(const Duration(hours: 20));
      expect(
        pending(offerSwitch: true, trialEnd: end).shownStatus(now),
        SubscriptionStatus.trialing,
      );
      expect(
        pending(
          offerSwitch: true,
          trialEnd: now.subtract(const Duration(days: 20)),
        ).shownStatus(now),
        SubscriptionStatus.active,
      );
    },
  );

  test(
    'a claim with no live period, and every other status, reads as itself',
    () {
      expect(
        pending(
          offerSwitch: false,
          left: const Duration(hours: -1),
        ).shownStatus(now),
        SubscriptionStatus.pending,
      );
      for (final status in SubscriptionStatus.values.where(
        (s) => s != SubscriptionStatus.pending,
      )) {
        final sub = SubscriptionModel(
          id: 's',
          userId: 'u',
          status: status,
          currentPeriodEnd: now.add(const Duration(days: 1)),
        );
        expect(sub.shownStatus(now), status, reason: status.name);
      }
    },
  );
}
