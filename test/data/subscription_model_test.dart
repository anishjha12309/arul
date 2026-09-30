// `GET /me` from a Worker that predates the cancel offer sends neither field, and the model must
// still parse — an unparseable row errors the whole entitlement fetch.

import 'package:arul/data/models/subscription_model.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _row([Map<String, dynamic> extra = const {}]) => {
  'id': 'sub_1',
  'user_id': 'u_1',
  'status': 'active',
  ...extra,
};

void main() {
  test('an older Worker reads as ₹199 with no offer', () {
    final sub = SubscriptionModel.fromJson(_row());
    expect(sub.pricePaise, 19900);
    expect(sub.cancelOfferEligible, isFalse);
  });

  test('explicit nulls read the same as absent fields', () {
    final sub = SubscriptionModel.fromJson(
      _row({'price_paise': null, 'cancel_offer_eligible': null}),
    );
    expect(sub.pricePaise, 19900);
    expect(sub.cancelOfferEligible, isFalse);
  });

  test('the Worker’s own values win', () {
    final sub = SubscriptionModel.fromJson(
      _row({'price_paise': 9900, 'cancel_offer_eligible': true}),
    );
    expect(sub.pricePaise, 9900);
    expect(sub.cancelOfferEligible, isTrue);
  });
}
