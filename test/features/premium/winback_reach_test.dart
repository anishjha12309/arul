// Who a ₹99 door may offer the win-back to, and where each door's tap lands. Pure rules: every
// screen and the Uninstall shortcut read these, so a wrong verdict here is a wrong sheet everywhere.

import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/domain/winback_reach.dart';
import 'package:flutter_test/flutter_test.dart';

SubscriptionModel _row({
  SubscriptionStatus status = SubscriptionStatus.cancelled,
  bool winback = true,
  bool trialSpent = true,
}) => SubscriptionModel(
  id: 'sub_1',
  userId: 'u_1',
  status: status,
  trialEnd: trialSpent ? DateTime(2026, 9, 1) : null,
  currentPeriodEnd: DateTime(2026, 10, 1),
  winbackOfferEligible: winback,
);

Entitlement _lapsed({
  SubscriptionStatus status = SubscriptionStatus.cancelled,
  bool winback = true,
  bool trialSpent = true,
}) => Entitlement(
  isPremium: false,
  subscription: _row(status: status, winback: winback, trialSpent: trialSpent),
);

AppConfigModel _config(Map<String, dynamic> flags) =>
    AppConfigModel(prices: const {}, policyUrls: const {}, featureFlags: flags);

void main() {
  group('winbackOffered — the Worker\'s verdict', () {
    test('needs the flag and a spent trial', () {
      expect(winbackOffered(_row()), isTrue);
      expect(winbackOffered(_row(winback: false)), isFalse);
      expect(winbackOffered(_row(trialSpent: false)), isFalse);
      expect(winbackOffered(null), isFalse);
    });
  });

  group('winbackReachable — a door no pay tap opened', () {
    test('only once premium has run out', () {
      expect(winbackReachable(_lapsed()), isTrue);
      expect(
        winbackReachable(_lapsed(status: SubscriptionStatus.expired)),
        isTrue,
      );
      // A cancelled row with days left is still premium: asking now would waste paid days.
      expect(
        winbackReachable(Entitlement(isPremium: true, subscription: _row())),
        isFalse,
      );
    });

    test('never mid-checkout, never without the Worker saying so', () {
      expect(
        winbackReachable(_lapsed(status: SubscriptionStatus.pending)),
        isFalse,
      );
      expect(winbackReachable(_lapsed(winback: false)), isFalse);
      expect(winbackReachable(_lapsed(trialSpent: false)), isFalse);
      expect(winbackReachable(const Entitlement.none()), isFalse);
      expect(winbackReachable(null), isFalse);
    });
  });

  group('WinbackEntry.fromRoute', () {
    test('nothing without the offer in the link', () {
      expect(WinbackEntry.fromRoute(source: 'daily'), isNull);
      expect(
        WinbackEntry.fromRoute(source: 'push', offer: 'cancel_99'),
        isNull,
      );
    });

    test('names each door; any gate source is a premium tap', () {
      WinbackEntry? of(String source) =>
          WinbackEntry.fromRoute(source: source, offer: 'winback_99');
      expect(of('push'), WinbackEntry.push);
      expect(of('daily'), WinbackEntry.daily);
      expect(of('uninstall_shortcut'), WinbackEntry.uninstallShortcut);
      expect(of('apply'), WinbackEntry.premiumTap);
      expect(of('ringtone_set'), WinbackEntry.premiumTap);
    });

    test('only the daily and Uninstall doors are sheet-only', () {
      expect(
        [
          for (final e in WinbackEntry.values)
            if (e.sheetOnly) e,
        ],
        [WinbackEntry.daily, WinbackEntry.uninstallShortcut],
      );
      expect(
        [for (final e in WinbackEntry.values) e.key],
        ['push', 'premium_tap', 'daily', 'uninstall_shortcut'],
      );
    });
  });

  group('WinbackReachFlags — kill switches, ON by default', () {
    test('absent config, absent key: every door is on', () {
      for (final flags in [
        WinbackReachFlags.from(null),
        WinbackReachFlags.from(_config(const {})),
        WinbackReachFlags.from(_config(const {'winback_reach': 'off'})),
      ]) {
        expect(flags.tapFirst, isTrue);
        expect(flags.dailySheet, isTrue);
        expect(flags.uninstallShortcut, isTrue);
        expect(flags.countdown, isTrue);
      }
    });

    test('only a literal false switches one off', () {
      final flags = WinbackReachFlags.from(
        _config(const {
          'winback_reach': {
            'tap_first': false,
            'daily_sheet': 'false',
            'uninstall_shortcut': 0,
            'countdown': false,
          },
        }),
      );
      expect(flags.tapFirst, isFalse);
      expect(flags.dailySheet, isTrue);
      expect(flags.uninstallShortcut, isTrue);
      expect(flags.countdown, isFalse);
    });
  });

  group('premiumGateLocation', () {
    test('a reachable cached /me adds the offer', () {
      expect(
        premiumGateLocation('apply', cached: _lapsed()),
        '/premium?source=apply&offer=winback_99',
      );
    });

    test('anyone else, or the switch off, gets the plain paywall', () {
      const plain = '/premium?source=apply';
      expect(premiumGateLocation('apply'), plain);
      expect(
        premiumGateLocation('apply', cached: _lapsed(trialSpent: false)),
        plain,
      );
      expect(
        premiumGateLocation(
          'apply',
          cached: _lapsed(status: SubscriptionStatus.pending),
        ),
        plain,
      );
      expect(
        premiumGateLocation(
          'apply',
          cached: _lapsed(),
          config: _config(const {
            'winback_reach': {'tap_first': false},
          }),
        ),
        plain,
      );
    });
  });

  group('decideShortcutLanding', () {
    const on = WinbackReachFlags();

    test('waits out the splash, then offers ₹99 to the reachable', () {
      expect(
        decideShortcutLanding(path: '/', entitlement: _lapsed(), flags: on),
        ShortcutLanding.hold,
      );
      expect(
        decideShortcutLanding(
          path: '/browse',
          entitlement: _lapsed(),
          flags: on,
        ),
        ShortcutLanding.offer,
      );
    });

    test('everything else is App info, so "Uninstall" stays true', () {
      ShortcutLanding at(
        String path,
        Entitlement? e, [
        WinbackReachFlags f = on,
      ]) => decideShortcutLanding(path: path, entitlement: e, flags: f);
      expect(at('/sign-in', _lapsed()), ShortcutLanding.appInfo);
      expect(at('/premium', _lapsed()), ShortcutLanding.appInfo);
      expect(at('/browse', null), ShortcutLanding.appInfo);
      expect(
        at('/browse', Entitlement(isPremium: true, subscription: _row())),
        ShortcutLanding.appInfo,
      );
      expect(
        at(
          '/browse',
          _lapsed(),
          const WinbackReachFlags(uninstallShortcut: false),
        ),
        ShortcutLanding.appInfo,
      );
    });
  });
}
