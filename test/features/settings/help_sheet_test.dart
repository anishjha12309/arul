// The Need help? sheet always offers support and delete. Manage subscription is the ONE row with a
// rule, and the rule is a promise: it appears only where `/premium` renders a manage view, so it can
// never land a reader on a sell. These pin every state the two test accounts cannot produce.

import 'dart:async';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/settings/presentation/help_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// A row, by the accessibility id the sheet stamps on it.
Finder _row(String id) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == id,
);

final _support = _row('arul_settings_help_support');
final _manage = _row('arul_settings_help_manage');
final _delete = _row('arul_settings_delete');

SubscriptionModel _sub(SubscriptionStatus status) =>
    SubscriptionModel(id: 'sub_1', userId: 'u_1', status: status);

Override _entitlement({required bool premium, SubscriptionStatus? status}) =>
    entitlementDetailProvider.overrideWith(
      (ref) async => Entitlement(
        isPremium: premium,
        subscription: status == null ? null : _sub(status),
      ),
    );

void main() {
  late HelpAction? picked;

  setUp(() => picked = null);

  Future<AppLocalizations> pump(
    WidgetTester tester, {
    required List<Override> overrides,
  }) async {
    // A fresh key remounts the whole tree -> a loop's next case starts with no sheet still open
    // over the button it has to tap.
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: overrides,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await showHelpSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(Scaffold).first));
  }

  group('Manage subscription is visible only where /premium manages', () {
    testWidgets('free with no row — support and delete only', (tester) async {
      await pump(tester, overrides: [_entitlement(premium: false)]);

      expect(_support, findsOneWidget);
      expect(_delete, findsOneWidget);
      expect(_manage, findsNothing);
    });

    testWidgets('an abandoned setup leaves a pending row and no manage', (
      tester,
    ) async {
      await pump(
        tester,
        overrides: [
          _entitlement(premium: false, status: SubscriptionStatus.pending),
        ],
      );

      expect(_support, findsOneWidget);
      expect(_manage, findsNothing);
    });

    testWidgets('trialing, active and cancelled each show it with their own '
        'status line', (tester) async {
      const cases = {
        SubscriptionStatus.trialing: 'trial',
        SubscriptionStatus.active: 'active',
        SubscriptionStatus.cancelled: 'cancelled',
      };
      for (final status in cases.keys) {
        final l10n = await pump(
          tester,
          overrides: [_entitlement(premium: true, status: status)],
        );
        final sub = switch (status) {
          SubscriptionStatus.trialing => l10n.settingsPremiumSubTrial,
          SubscriptionStatus.active => l10n.settingsPremiumSubActive,
          _ => l10n.settingsPremiumSubCancelled,
        };

        expect(_manage, findsOneWidget, reason: status.name);
        expect(find.text(sub), findsOneWidget, reason: status.name);
      }
    });

    testWidgets('a lapsed plan hides it even while the flag still says premium', (
      tester,
    ) async {
      // The status filter is doing the work here, not the flag — `/premium` would sell to these.
      for (final status in const [
        SubscriptionStatus.expired,
        SubscriptionStatus.paused,
      ]) {
        await pump(
          tester,
          overrides: [_entitlement(premium: true, status: status)],
        );

        expect(_manage, findsNothing, reason: status.name);
        expect(_support, findsOneWidget, reason: status.name);
        expect(_delete, findsOneWidget, reason: status.name);
      }
    });

    testWidgets('reward-only premium has no row to manage', (tester) async {
      await pump(tester, overrides: [_entitlement(premium: true)]);

      expect(_manage, findsNothing);
      expect(_delete, findsOneWidget);
    });

    testWidgets('an entitlement error still offers support and delete', (
      tester,
    ) async {
      await pump(
        tester,
        overrides: [
          entitlementDetailProvider.overrideWith(
            (ref) async => throw Exception('offline'),
          ),
        ],
      );

      expect(_support, findsOneWidget);
      expect(_delete, findsOneWidget);
      expect(_manage, findsNothing);
    });

    testWidgets(
      'a cold open resolves under the open sheet and the row arrives',
      (tester) async {
        final read = Completer<Entitlement>();
        await pump(
          tester,
          overrides: [
            entitlementDetailProvider.overrideWith((ref) => read.future),
          ],
        );

        expect(_manage, findsNothing, reason: 'nothing is known yet');

        read.complete(
          Entitlement(
            isPremium: true,
            subscription: _sub(SubscriptionStatus.active),
          ),
        );
        await tester.pumpAndSettle();

        expect(_manage, findsOneWidget);
      },
    );
  });

  group('the sheet resolves a choice and acts on nothing', () {
    testWidgets('each row pops its own action', (tester) async {
      final taps = {
        _support: HelpAction.support,
        _manage: HelpAction.manage,
        _delete: HelpAction.delete,
      };
      for (final MapEntry(key: row, value: action) in taps.entries) {
        await pump(
          tester,
          overrides: [
            _entitlement(premium: true, status: SubscriptionStatus.active),
          ],
        );
        await tester.tap(row);
        await tester.pumpAndSettle();

        expect(picked, action);
        expect(_support, findsNothing, reason: 'the sheet closed');
      }
    });

    testWidgets('a dismissed sheet resolves to nothing', (tester) async {
      await pump(tester, overrides: [_entitlement(premium: false)]);

      // The barrier, which is what a tap outside the sheet hits.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(picked, isNull);
      expect(_support, findsNothing);
    });
  });
}
