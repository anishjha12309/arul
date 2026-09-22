import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/upi/upi_apps.dart';
import 'package:arul/features/premium/presentation/premium_screen.dart';

UpiApp _app(String package) => UpiApp(packageName: package, label: package);

Map<String, Object?> _props({
  List<UpiApp> apps = const [],
  List<String> otherPackages = const [],
  String? defaultPackage,
  bool trialEligible = true,
  String variant = 'trial',
}) => paywallShownProperties(
  source: 'wallpaper_apply',
  apps: apps,
  otherPackages: otherPackages,
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
      expect(props['upi_other_count'], '0');
      expect(props['upi_others'], 'none');
    });

    test('a phone we REFUSED reads differently from a phone that cannot pay', () {
      // The distinction the whole parameter exists for: both report `has_upi_app: no`, and only one
      // of them is a person without a way to pay. 13% of Subscribe taps sat in this bucket.
      final cannotPay = _props();
      final refused = _props(
        otherPackages: const ['com.csam.icici.bank.imobile'],
      );

      expect(cannotPay['has_upi_app'], refused['has_upi_app']);
      expect(cannotPay['upi_other_count'], '0');
      expect(refused['upi_other_count'], '1');
      expect(refused['upi_others'], 'com.csam.icici.bank.imobile');
    });

    test('unoffered packages are RAW and sorted — a code would hide the names '
        'this parameter exists to learn', () {
      final props = _props(
        apps: [_app('com.phonepe.app')],
        otherPackages: const ['com.msf.kbank.mobile', 'com.axis.mobile'],
      );

      // `upiAppCode` would file both as `other`; the report needs the names themselves.
      expect(props['upi_others'], 'com.axis.mobile,com.msf.kbank.mobile');
      expect(props['upi_other_count'], '2');
      // Offered and refused are independent axes — having PhonePe says nothing about the rest.
      expect(props['has_upi_app'], 'yes');
    });

    test('the pack takes WHOLE names and the count survives the truncation', () {
      // GA4 drops a parameter value over 100 characters outright, so a long list must lose entries
      // rather than the parameter. A half-written package name would be worse than a missing one.
      final many = [
        for (var i = 0; i < 6; i++) 'com.bank$i.mobile.upi.autopay.handler',
      ];
      final props = _props(otherPackages: many);
      final packed = props['upi_others']! as String;

      expect(packed.length, lessThanOrEqualTo(100));
      for (final part in packed.split(',')) {
        expect(many, contains(part), reason: 'no name may be cut mid-value');
      }
      // The count is what survives: the phone had 6, the value could only carry some of them.
      expect(props['upi_other_count'], '4plus');
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

    test('a phone carrying the WHOLE allowlist reports every app — no code is '
        'cut off the end of the list', () {
      // The list is PhonePe's seven published mandate apps plus the sandbox simulator, and it grew
      // under a packer that took a fixed six: the eighth app vanished from the value while the
      // count still said `4plus`, so the breakdown disagreed with itself. Every code must survive.
      final props = _props(
        apps: [
          _app('com.phonepe.app'),
          _app('com.google.android.apps.nbu.paisa.user'),
          _app('net.one97.paytm'),
          _app('in.org.npci.upiapp'),
          _app('com.dreamplug.androidapp'),
          _app('in.amazon.mShop.android.shopping'),
          _app('money.super.payments'),
          _app('com.phonepe.simulator'),
        ],
      );

      expect(
        props['upi_apps'],
        'amazon,bhim,cred,gpay,paytm,phonepe,ppesim,supermoney',
      );
      // Still inside GA4's parameter-value limit, which is what the packer is for.
      expect((props['upi_apps']! as String).length, lessThanOrEqualTo(100));
    });

    test('every value is a String within GA4 app-stream limits', () {
      // GA4 does not parse numeric parameter values into event-scoped custom dimensions on APP
      // streams, and the GA4 sink coerces a bool to 1/0 -> a numeric value here is collected and can
      // then never be broken down in a report. 100 characters is the parameter-value limit.
      final props = _props(
        apps: [_app('com.phonepe.app')],
        otherPackages: const [
          'com.csam.icici.bank.imobile',
          'com.msf.kbank.mobile',
          'com.bankofbaroda.mconnect',
        ],
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
