import 'package:arul/features/premium/presentation/premium_screen.dart';
import 'package:arul/features/premium/providers/premium_purchase_provider.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 9, 24, 12);

PurchaseResumable _openAt(String app) => PurchaseResumable(
  intentUrl: 'upi://mandate?tr=DKS_1',
  targetApp: app,
  merchantOrderId: 'DKS_1',
  launchedAt: _now,
  expiresAt: _now.add(const Duration(minutes: 5)),
);

const _phonePe = 'com.phonepe.app';
const _gpay = 'com.google.android.apps.nbu.paisa.user';

/// The two decisions the return page rests on, pinned where a regression would cost money:
/// opening the page on a return that was actually an approval, or firing a second initiate over an
/// order the person could still have approved.
void main() {
  group('opensReturnPage', () {
    bool opens({
      PurchaseState? previous = const PurchaseProcessing(),
      PurchaseState? next,
      bool trialSell = true,
      bool pageUp = false,
      bool enabled = true,
    }) => opensReturnPage(
      previous: previous,
      next: next ?? _openAt(_phonePe),
      trialSell: trialSell,
      pageUp: pageUp,
      enabled: enabled,
    );

    test('an unapproved return on the trial sell opens it', () {
      expect(opens(), isTrue);
    });

    test('an approval never opens it', () {
      expect(opens(next: const PurchaseSuccess()), isFalse);
    });

    test('the ₹199 sell never opens it — its clip pitches the ₹2 trial', () {
      expect(opens(trialSell: false), isFalse);
    });

    test('a return to the page itself does not stack a second one', () {
      expect(opens(pageUp: true), isFalse);
    });

    test('return_video.enabled:false keeps the old flow', () {
      expect(opens(enabled: false), isFalse);
    });

    test('only the step INTO resumable counts, not a re-emission', () {
      expect(opens(previous: _openAt(_phonePe)), isFalse);
    });

    test('every return counts — a second abandon opens it again', () {
      // After the page closed, the next tap → UPI app → unapproved return is a fresh step in.
      expect(opens(previous: const PurchaseProcessing()), isTrue);
    });
  });

  group('returnStartAction', () {
    test('the app holding the order reopens that order', () {
      expect(
        returnStartAction(_openAt(_phonePe), _phonePe),
        ReturnStart.resume,
      );
    });

    test('another app switches — the open order is dropped first', () {
      expect(
        returnStartAction(_openAt(_phonePe), _gpay),
        ReturnStart.switchApp,
      );
    });

    test('with the window gone, any app is a fresh checkout', () {
      expect(
        returnStartAction(const PurchaseIdle(), _phonePe),
        ReturnStart.fresh,
      );
    });

    test('QR over an open app order switches, even at PhonePe', () {
      // The QR names PhonePe only as a formality; picking it is still a change of route.
      expect(
        returnStartAction(_openAt(_phonePe), kUpiPickQr),
        ReturnStart.qrSwitch,
      );
    });

    test('QR while its code is live shows that code again', () {
      expect(
        returnStartAction(
          PurchaseScannable(
            intentUrl: 'upi://mandate?tr=DKS_1',
            merchantOrderId: 'DKS_1',
            expiresAt: _now,
          ),
          kUpiPickQr,
        ),
        ReturnStart.qrReopen,
      );
    });

    test('QR with nothing open starts a fresh code', () {
      expect(
        returnStartAction(const PurchaseIdle(), kUpiPickQr),
        ReturnStart.qrFresh,
      );
    });
  });
}
