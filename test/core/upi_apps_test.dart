// The app-side half of the mandate picker's contract with `UpiIntentChannel.kt`.
//
// The channel returns only allowlisted packages that ALSO resolve a mandate-shaped intent, so an
// empty list here means "no app on this phone can take a mandate" — the install prompt, never the
// hosted page. What this file pins is everything Dart does with that list: it must survive a
// malformed entry rather than throw, and the remembered pick must lead without dropping anyone.
import 'package:arul/core/upi/upi_apps.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _phonepe = 'com.phonepe.app';
const _paytm = 'net.one97.paytm';
const _gpay = 'com.google.android.apps.nbu.paisa.user';
const _bhim = 'in.org.npci.upiapp';

UpiApp _app(String pkg) => UpiApp(packageName: pkg, label: pkg);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpiApps.installed parsing', () {
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
      answer(<Object?>[
        {'package': _phonepe, 'label': 'PhonePe', 'icon': null},
        {'package': _paytm, 'label': 'Paytm', 'icon': null},
        {'package': _gpay, 'label': 'Google Pay', 'icon': null},
        {'package': _bhim, 'label': 'BHIM', 'icon': null},
      ]);

      final apps = await UpiApps.installed();

      expect(apps.map((a) => a.packageName), [_phonepe, _paytm, _gpay, _bhim]);
      expect(apps.first.label, 'PhonePe');
      expect(apps.first.icon, isNull);
    });

    test('carries the icon bytes through untouched', () async {
      final png = Uint8List.fromList([137, 80, 78, 71]);
      answer(<Object?>[
        {'package': _phonepe, 'label': 'PhonePe', 'icon': png},
      ]);

      final apps = await UpiApps.installed();

      expect(apps.single.icon, png);
    });

    test('drops a malformed entry instead of throwing — one bad row must not '
        'cost the whole picker', () async {
      answer(<Object?>[
        {'package': _phonepe, 'label': 'PhonePe'},
        {'package': 42, 'label': 'nonsense'},
        {'label': 'no package'},
        'not a map',
        {'package': _gpay, 'label': 'Google Pay'},
      ]);

      final apps = await UpiApps.installed();

      expect(apps.map((a) => a.packageName), [_phonepe, _gpay]);
    });

    test('a channel failure is EMPTY, never a throw — the paywall shows the '
        'install prompt and the CTA stays dead', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'BOOM'),
      );

      expect(await UpiApps.installed(), isEmpty);
    });

    test('a null reply is empty too', () async {
      answer(null);
      expect(await UpiApps.installed(), isEmpty);
    });
  });

  group('UpiApps.ordered', () {
    // The shipped list after CRED, Amazon Pay and SuperMoney came out.
    final shortened = [_phonepe, _paytm, _gpay, _bhim].map(_app).toList();

    test('no remembered pick leaves the owner order alone', () {
      expect(UpiApps.ordered(shortened, null).map((a) => a.packageName), [
        _phonepe,
        _paytm,
        _gpay,
        _bhim,
      ]);
    });

    test('the remembered pick leads and nobody is lost behind it', () {
      final out = UpiApps.ordered(shortened, _gpay);

      expect(out.map((a) => a.packageName), [_gpay, _phonepe, _paytm, _bhim]);
      expect(out, hasLength(shortened.length));
    });

    test('a remembered head is already in place — no needless rebuild', () {
      expect(
        identical(UpiApps.ordered(shortened, _phonepe), shortened),
        isTrue,
      );
    });

    test('a remembered app the probe or an uninstall removed moves nothing', () {
      // CRED was in MANDATE_APPS and is not any more: someone who picked it still has it in prefs.
      expect(
        UpiApps.ordered(
          shortened,
          'com.dreamplug.androidapp',
        ).map((a) => a.packageName),
        [_phonepe, _paytm, _gpay, _bhim],
      );
    });

    test('an empty list stays empty whatever is remembered', () {
      expect(UpiApps.ordered(const [], _phonepe), isEmpty);
    });
  });
}
