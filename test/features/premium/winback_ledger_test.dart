// The daily ₹99 sheet's memory: at most one unprompted sheet per IST day, and two dismissals in a
// row rest it for a week (owner, 12 Oct 2026).

import 'package:arul/features/premium/domain/winback_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late DateTime now;
  late WinbackLedger ledger;

  // Noon IST on 12 Oct 2026.
  final noon = DateTime.utc(2026, 10, 12, 6, 30);

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    now = noon;
    ledger = WinbackLedger(prefs, clock: () => now);
  });

  test('istDay turns over at IST midnight, not UTC', () {
    expect(istDay(DateTime.utc(2026, 10, 12, 18, 29, 59)), '2026-10-12');
    expect(istDay(DateTime.utc(2026, 10, 12, 18, 30)), '2026-10-13');
    expect(istDay(DateTime.utc(2026, 12, 31, 20)), '2027-01-01');
  });

  test('one sheet a day, from any door', () async {
    expect(ledger.canAutoShow(), isTrue);
    await ledger.noteShown();
    expect(ledger.canAutoShow(), isFalse);
    now = noon.add(const Duration(hours: 11, minutes: 59));
    expect(ledger.canAutoShow(), isFalse, reason: '23:59 IST, same day');
    now = noon.add(const Duration(hours: 12));
    expect(ledger.canAutoShow(), isTrue, reason: 'midnight IST');
  });

  test('two dismissals in a row: seven days with none, then back', () async {
    await ledger.noteShown();
    await ledger.noteDailyDismissed();
    now = noon.add(const Duration(days: 1));
    expect(
      ledger.canAutoShow(),
      isTrue,
      reason: 'one dismissal pauses nothing',
    );

    await ledger.noteShown();
    await ledger.noteDailyDismissed();
    for (var day = 2; day <= 8; day++) {
      now = noon.add(Duration(days: day));
      expect(
        ledger.canAutoShow(),
        isFalse,
        reason: 'day $day is inside the pause',
      );
    }
    now = noon.add(const Duration(days: 9));
    expect(ledger.canAutoShow(), isTrue);
    expect(
      prefs.getInt(WinbackLedger.dismissalsKey),
      isNull,
      reason: 'the count restarts',
    );
  });

  test('an accept in between breaks the run', () async {
    await ledger.noteDailyDismissed();
    await ledger.noteAccepted();
    await ledger.noteDailyDismissed();
    now = noon.add(const Duration(days: 1));
    expect(ledger.canAutoShow(), isTrue);
    expect(prefs.getString(WinbackLedger.pausedUntilKey), isNull);
  });

  test('a clock set backwards only waits longer', () async {
    await ledger.noteShown();
    now = noon.subtract(const Duration(days: 3));
    expect(ledger.canAutoShow(), isFalse);
  });
}
