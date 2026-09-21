import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/presentation/premium_screen.dart';

UpiApp _app(String package) => UpiApp(packageName: package, label: package);

Map<String, Object?> _props({
  List<UpiApp> apps = const [],
  String? defaultPackage,
  bool trialEligible = true,
  String variant = 'trial',
}) => paywallShownProperties(
  source: 'wallpaper_apply',
  apps: apps,
  defaultPackage: defaultPackage,
  trialEligible: trialEligible,
  variant: variant,
);

void main() {
  group('paywallShownProperties', () {
    test('no installed app is its own two-valued answer, never an absence', () {
      // The whole point of the event: a phone that cannot pay reads `no`, not a missing parameter,
      // because a missing parameter is indistinguishable from an old build in GA4.
      final props = _props();
      expect(props['has_upi_app'], 'no');
      expect(props['upi_apps'], 'none');
      expect(props['upi_app_count'], '0');
      expect(props['default_app'], 'none');
    });

    test('the app list is SORTED, so one installed set is one value', () {
      // The picker floats the remembered app to the head -> the same two apps would otherwise file
      // as `phonepe,gpay` and `gpay,phonepe` and split every breakdown in half.
      final ordered = _props(
        apps: [_app('com.phonepe.app'), _app('net.one97.paytm')],
      );
      final reversed = _props(
        apps: [_app('net.one97.paytm'), _app('com.phonepe.app')],
      );
      expect(ordered['upi_apps'], 'paytm,phonepe');
      expect(reversed['upi_apps'], ordered['upi_apps']);
    });

    test('an unlisted package buckets as other rather than leaking a name', () {
      final props = _props(
        apps: [_app('com.example.wallet')],
        defaultPackage: 'com.example.wallet',
      );
      expect(props['upi_apps'], 'other');
      expect(props['default_app'], 'other');
      expect(props['has_upi_app'], 'yes');
    });

    test('the count caps, so the dimension can never be high-cardinality', () {
      final props = _props(
        apps: [
          _app('com.phonepe.app'),
          _app('com.google.android.apps.nbu.paisa.user'),
          _app('net.one97.paytm'),
          _app('in.org.npci.upiapp'),
          _app('com.phonepe.simulator'),
        ],
      );
      expect(props['upi_app_count'], '4plus');
    });

    test('every value is a String within GA4 app-stream limits', () {
      // GA4 does not parse numeric parameter values into event-scoped custom dimensions on APP
      // streams, and the GA4 sink coerces a bool to 1/0 -> a numeric value here is collected and can
      // then never be broken down in a report. 100 characters is the parameter-value limit.
      final props = _props(
        apps: [_app('com.phonepe.app')],
        defaultPackage: 'com.phonepe.app',
        trialEligible: false,
        variant: 'paid',
      );
      expect(props['trial_eligible'], 'no');
      for (final entry in props.entries) {
        expect(
          entry.value,
          isA<String>(),
          reason: '${entry.key} must be a string for GA4 app streams',
        );
        expect((entry.value! as String).length, lessThanOrEqualTo(100));
      }
    });

    test('the gate verb rides as paywall_source, never as source', () {
      // GA4 owns `source` as a traffic dimension -> a parameter of that name collides with it.
      final props = _props();
      expect(props['paywall_source'], 'wallpaper_apply');
      expect(props.containsKey('source'), isFalse);
    });
  });
}
