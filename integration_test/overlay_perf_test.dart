// Frame timing for every toast, sheet and dialog, on a real phone in a PROFILE build.
//
//     flutter drive --profile --no-dds --device-user 0 -d <serial> \
//       --driver=test_driver/perf_driver.dart --target=integration_test/overlay_perf_test.dart
//
// Each overlay opens and closes five times under `watchPerformance`; the driver writes the
// summary to build/overlay_perf.json. Read it against the panel's own frame budget.

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/theme/theme.dart';
import 'package:arul/app/widgets/arul_toast.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/subscription_model.dart';
import 'package:arul/features/premium/domain/entitlement.dart';
import 'package:arul/features/premium/providers/entitlement_provider.dart';
import 'package:arul/features/settings/presentation/confirm_dialog.dart';
import 'package:arul/features/settings/presentation/help_sheet.dart';
import 'package:arul/features/settings/presentation/language_sheet.dart';
import 'package:arul/features/settings/presentation/theme_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    Widget button(String label, Future<void> Function(BuildContext) open) =>
        TextButton(onPressed: () => open(context), child: Text(label));
    return Scaffold(
      body: SafeArea(
        child: Wrap(
          children: [
            button('help', showHelpSheet),
            button('language', (c) => showLanguageSheet(c, 'English')),
            button('theme', showThemeSheet),
            button(
              'dialog',
              (c) => showArulConfirmDialog(
                c,
                title: 'Logout?',
                message: 'You can sign back in anytime with Google.',
                confirmLabel: 'Logout',
              ),
            ),
            button('toast', (c) async {
              showArulToast(
                c,
                'Saved to your gallery',
                kind: ToastKind.success,
              );
            }),
          ],
        ),
      ),
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('overlays open and close inside the frame budget', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    for (final dark in [true, false]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            entitlementDetailProvider.overrideWith(
              (ref) async => Entitlement(
                isPremium: true,
                subscription: SubscriptionModel(
                  id: 'sub_1',
                  userId: 'u_1',
                  status: SubscriptionStatus.trialing,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: dark ? ArulTheme.dark() : ArulTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const _Host(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> open(String label) async {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        switch (label) {
          case 'dialog':
            await tester.tap(find.text('Cancel'));
          case 'toast':
            // A tap sends it away early; the next toast would replace it anyway.
            await tester.tap(find.text('Saved to your gallery'));
          default:
            // The scrim above the sheet closes it, as a person would.
            await tester.tapAt(const Offset(200, 120));
        }
        await tester.pumpAndSettle();
      }

      const kinds = ['help', 'language', 'theme', 'dialog', 'toast'];
      final mode = dark ? 'dark' : 'light';
      // The FIRST open of each pays its one-time costs (asset decode, first layout); measured
      // apart from the warm repeats, which are what a person feels every other time.
      await binding.watchPerformance(() async {
        for (final kind in kinds) {
          await open(kind);
        }
      }, reportKey: 'overlay_cold_$mode');
      for (final kind in kinds) {
        await binding.watchPerformance(() async {
          for (var i = 0; i < 5; i++) {
            await open(kind);
          }
        }, reportKey: 'overlay_${kind}_$mode');
      }
    }
  });
}
