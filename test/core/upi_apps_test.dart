// The app-side half of the mandate picker's contract with `UpiIntentChannel.kt`.
//
// The channel answers with two halves: `offered`, the allowlisted packages that ALSO resolve a
// mandate-shaped intent, and `others`, the mandate handlers the allowlist drops. An empty `offered`
// means "no app we sell to" — the install prompt, never the hosted page — while a non-empty `others`
// beside it means the phone CAN pay and we refused, which is a different fact and reported as one.
// What this file pins is everything Dart does with that reply: it must survive a malformed entry
// rather than throw, and the remembered pick must lead without dropping anyone.
import 'package:arul/core/upi/upi_apps.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _phonepe = 'com.phonepe.app';
const _paytm = 'net.one97.paytm';
const _gpay = 'com.google.android.apps.nbu.paisa.user';
const _bhim = 'in.org.npci.upiapp';
const _cred = 'com.dreamplug.androidapp';
const _amazon = 'in.amazon.mShop.android.shopping';
const _supermoney = 'money.super.payments';
const _ppesim = 'com.phonepe.simulator';

UpiApp _app(String pkg) => UpiApp(packageName: pkg, label: pkg);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpiApps.scan parsing', () {
    const channel = MethodChannel('com.hsrutility.arul/upi_intent');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void answer(Object? reply) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'listUpiApps');
        return reply;
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('keeps the channel order — the head is the default for everyone who '
        'never opens the picker', () async {
      answer(<String, Object?>{
        'offered': <Object?>[
          {'package': _phonepe, 'label': 'PhonePe', 'icon': null},
          {'package': _paytm, 'label': 'Paytm', 'icon': null},
          {'package': _gpay, 'label': 'Google Pay', 'icon': null},
          {'package': _bhim, 'label': 'BHIM', 'icon': null},
        ],
        'others': <Object?>[],
      });

      final scan = await UpiApps.scan();

      expect(scan.apps.map((a) => a.packageName), [
        _phonepe,
        _paytm,
        _gpay,
        _bhim,
      ]);
      expect(scan.apps.first.label, 'PhonePe');
      expect(scan.apps.first.icon, isNull);
    });

    test('carries the icon bytes through untouched', () async {
      final png = Uint8List.fromList([137, 80, 78, 71]);
      answer(<String, Object?>{
        'offered': <Object?>[
          {'package': _phonepe, 'label': 'PhonePe', 'icon': png},
        ],
      });

      final scan = await UpiApps.scan();

      expect(scan.apps.single.icon, png);
    });

    test('drops a malformed entry instead of throwing — one bad row must not '
        'cost the whole picker', () async {
      answer(<String, Object?>{
        'offered': <Object?>[
          {'package': _phonepe, 'label': 'PhonePe'},
          {'package': 42, 'label': 'nonsense'},
          {'label': 'no package'},
          'not a map',
          {'package': _gpay, 'label': 'Google Pay'},
        ],
        'others': <Object?>['com.example.wallet', 7, null],
      });

      final scan = await UpiApps.scan();

      expect(scan.apps.map((a) => a.packageName), [_phonepe, _gpay]);
      // A non-String in `others` is dropped the same way — the report must never carry a null.
      expect(scan.otherPackages, ['com.example.wallet']);
    });

    test('a channel failure is EMPTY, never a throw — the paywall shows the '
        'install prompt and the CTA stays dead', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'BOOM'),
      );

      final scan = await UpiApps.scan();
      expect(scan.apps, isEmpty);
      expect(scan.otherPackages, isEmpty);
    });

    test('a null reply is empty too', () async {
      answer(null);
      final scan = await UpiApps.scan();
      expect(scan.apps, isEmpty);
      expect(scan.otherPackages, isEmpty);
    });

    test('a reply with no `others` key is not a claim that none exist — it is '
        'an empty report, and the offered half still parses', () async {
      // The probe can fail on device while the allowlist walk still answers: Kotlin sends an empty
      // `others` there, and a missing key must read the same rather than throw.
      answer(<String, Object?>{
        'offered': <Object?>[
          {'package': _phonepe, 'label': 'PhonePe'},
        ],
      });

      final scan = await UpiApps.scan();

      expect(scan.apps.single.packageName, _phonepe);
      expect(scan.otherPackages, isEmpty);
    });

    test('mandate handlers we refuse come back verbatim — codes would hide the '
        'names this report exists to learn', () async {
      answer(<String, Object?>{
        'offered': <Object?>[],
        'others': <Object?>[
          'com.csam.icici.bank.imobile',
          'com.msf.kbank.mobile',
        ],
      });

      final scan = await UpiApps.scan();

      expect(scan.apps, isEmpty);
      expect(scan.otherPackages, [
        'com.csam.icici.bank.imobile',
        'com.msf.kbank.mobile',
      ]);
    });
  });

  // The package -> short code map is what every UPI number in GA4 is bucketed by, and it is a
  // SEPARATE list from the channel's. An app on the allowlist with no code here does not break:
  // it reads as `other` and disappears into that bucket, which is why the drift is worth pinning.
  group('upiAppCode', () {
    test('every allowlisted package has its own code — none falls into '
        '`other`, where a whole app would hide', () {
      // Mirrors MANDATE_APPS in UpiIntentChannel.kt: PhonePe's seven published mandate apps plus
      // the sandbox simulator.
      const codes = {
        _phonepe: 'phonepe',
        _gpay: 'gpay',
        _paytm: 'paytm',
        _bhim: 'bhim',
        _cred: 'cred',
        _amazon: 'amazon',
        _supermoney: 'supermoney',
        _ppesim: 'ppesim',
      };

      for (final entry in codes.entries) {
        expect(upiAppCode(entry.key), entry.value, reason: entry.key);
      }
      // Distinct codes, or two apps would merge into one row in the breakdown.
      expect(codes.values.toSet(), hasLength(codes.length));
    });

    test('a package off the list is `other`, never a crash', () {
      expect(upiAppCode('com.msf.kbank.mobile'), 'other');
      expect(upiAppCode(''), 'other');
    });
  });

  group('UpiApps.ordered', () {
    // A fixture, not the shipped list — what is pinned here is the ordering, not the membership.
    final installed = [_phonepe, _paytm, _gpay, _bhim].map(_app).toList();

    test('no remembered pick leaves the owner order alone', () {
      expect(UpiApps.ordered(installed, null).map((a) => a.packageName), [
        _phonepe,
        _paytm,
        _gpay,
        _bhim,
      ]);
    });

    test('the remembered pick leads and nobody is lost behind it', () {
      final out = UpiApps.ordered(installed, _gpay);

      expect(out.map((a) => a.packageName), [_gpay, _phonepe, _paytm, _bhim]);
      expect(out, hasLength(installed.length));
    });

    test('a remembered head is already in place — no needless rebuild', () {
      expect(
        identical(UpiApps.ordered(installed, _phonepe), installed),
        isTrue,
      );
    });

    test('a remembered app the probe or an uninstall removed moves nothing', () {
      // Allowlisted but not on THIS phone: the pick survives in prefs long after the app goes, and
      // a tail app like CRED is the likely one to be uninstalled.
      expect(UpiApps.ordered(installed, _cred).map((a) => a.packageName), [
        _phonepe,
        _paytm,
        _gpay,
        _bhim,
      ]);
    });

    test('an empty list stays empty whatever is remembered', () {
      expect(UpiApps.ordered(const [], _phonepe), isEmpty);
    });
  });
}
