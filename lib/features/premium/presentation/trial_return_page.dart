import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/premium_purchase_provider.dart';
import 'paywall_ornaments.dart';
import 'paywall_view.dart';
import 'upi_option_rows.dart';

/// The page a trial-eligible user lands on after coming back from the UPI app WITHOUT approving.
///
/// Pushed over the trial screen by [PremiumScreen] on every unapproved return; back lands on that
/// screen as it was. It carries the "don't go back" clip in the phone's language, every UPI app laid
/// out as a row, and Start Free Trial — and nothing else (owner's call: no offer panel, ticker,
/// feature row or terms line).
///
/// A tap on a row only SELECTS it: the rows are the sheet's rows made permanent, and the one thing
/// that acts is the button. What the button does is [PremiumScreen]'s business — reopen the pending
/// mandate, switch it to another app, or put it on screen as a QR — because that is the same order
/// logic the trial screen runs, and a second copy of it here would drift.
class TrialReturnPage extends ConsumerStatefulWidget {
  const TrialReturnPage({
    super.key,
    required this.clip,
    required this.initialSelection,
    required this.rememberedPackage,
    required this.onRememberApp,
    required this.onStart,
  });

  /// The return clip's card, or null when no cut resolves — the page still works without it.
  final Widget? clip;

  /// The app holding the open order, else the remembered pick — floated to the head and selected.
  final String? initialSelection;

  /// The app a previous visit settled on — the one row that earns the "Last used" badge.
  final String? rememberedPackage;

  /// A row tap on an app writes it as the remembered pick, exactly as the sheet does. Never called
  /// for the QR row: the QR is a one-time route, never a default.
  final ValueChanged<String> onRememberApp;

  /// The button, with the current selection — a package name or [kUpiPickQr].
  final ValueChanged<String> onStart;

  @override
  ConsumerState<TrialReturnPage> createState() => _TrialReturnPageState();
}

class _TrialReturnPageState extends ConsumerState<TrialReturnPage> {
  late String? _selection = widget.initialSelection;

  /// The row order, fixed for the page's life. Floating the tapped row to the head would move the
  /// list under the finger that just chose it.
  List<String>? _order;

  List<UpiApp> _ordered(List<UpiApp> apps) {
    final order = _order;
    if (order == null ||
        order.length != apps.length ||
        !apps.every((a) => order.contains(a.packageName))) {
      // First answer, or the installed set changed underneath (an app installed or removed) —
      // the only time the order is rebuilt.
      final fresh = UpiApps.ordered(apps, widget.initialSelection);
      _order = [for (final a in fresh) a.packageName];
      return fresh;
    }
    return [for (final p in order) apps.firstWhere((a) => a.packageName == p)];
  }

  void _select(String selection) {
    if (selection == _selection) return;
    setState(() => _selection = selection);
    if (selection != kUpiPickQr) widget.onRememberApp(selection);
  }

  @override
  Widget build(BuildContext context) {
    final purchase = ref.watch(premiumPurchaseProvider);
    final busy = purchase is PurchaseLoading || purchase is PurchaseProcessing;
    final apps = _ordered(
      ref.watch(installedUpiAppsProvider).asData?.value.apps ?? const [],
    );
    // A selection that vanished (the app was uninstalled while away) falls back to the head, so the
    // button is never armed with nothing behind it.
    final selection =
        (_selection == kUpiPickQr ||
            apps.any((a) => a.packageName == _selection))
        ? _selection
        : (apps.isEmpty ? null : apps.first.packageName);

    return ArulTrialReturnView(
      clip: widget.clip,
      apps: apps,
      selection: selection,
      lastUsedPackage: widget.rememberedPackage,
      busy: busy,
      onBack: () => Navigator.of(context).maybePop(),
      onSelect: _select,
      onStart: selection == null ? null : () => widget.onStart(selection),
    );
  }
}

/// The return page's layout, stateless so every phone size can be pinned by a test.
///
/// Nav pinned on top and the button pinned at the foot; the clip and the rows scroll together
/// between them, so a short phone scrolls the list and never loses the button. The clip keeps its
/// full 16:9 everywhere — a smaller phone pays in rows below the fold, never in a cropped face.
class ArulTrialReturnView extends StatelessWidget {
  const ArulTrialReturnView({
    super.key,
    required this.clip,
    required this.apps,
    required this.selection,
    required this.lastUsedPackage,
    required this.busy,
    required this.onBack,
    required this.onSelect,
    required this.onStart,
  });

  final Widget? clip;
  final List<UpiApp> apps;

  /// A package name, [kUpiPickQr], or null before the app probe answers.
  final String? selection;
  final String? lastUsedPackage;
  final bool busy;
  final VoidCallback onBack;
  final ValueChanged<String> onSelect;

  /// Null leaves the button dead — nothing selected yet.
  final VoidCallback? onStart;

  /// The page's one column edge — the clip, the heading and the rows all sit on it.
  static const double gutter = ArulTokens.screenPadding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final clip = this.clip;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Ivory ground → dark system-bar icons, as on the trial screen under it.
      value: const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: ArulTokens.paywallCream,
        body: SafeArea(
          child: PaywallGround(
            child: Column(
              children: [
                PaywallNavRow(onBack: onBack),
                // The trial screen's own rule for slack: centre the middle between the pinned
                // ends rather than pool it above the button, and scroll once there is none.
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, constraints) => SingleChildScrollView(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight - 12,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ?clip,
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      gutter,
                                      clip == null ? 18 : 16,
                                      gutter,
                                      0,
                                    ),
                                    child: Text(
                                      l10n.upiPickerTitle,
                                      key: const Key('return-pay-using'),
                                      style: ArulTokens.paywallWordmark
                                          .copyWith(fontSize: 17, height: 1.25),
                                    ),
                                  ),
                                  // The sheet's own header rule -> the list reads as that sheet, opened out.
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      gutter,
                                      9,
                                      gutter,
                                      0,
                                    ),
                                    child: Container(
                                      height: 1,
                                      decoration: const BoxDecoration(
                                        gradient:
                                            ArulTokens.paywallHeaderHairline,
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      gutter,
                                      10,
                                      gutter,
                                      0,
                                    ),
                                    child: Column(
                                      children: [
                                        for (final (i, app) in apps.indexed)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 8,
                                            ),
                                            child: UpiOptionRow(
                                              app: app,
                                              identifier:
                                                  'arul_return_upi_option_$i',
                                              selected:
                                                  app.packageName == selection,
                                              lastUsed:
                                                  app.packageName ==
                                                  lastUsedPackage,
                                              showTick: true,
                                              onTap: busy
                                                  ? null
                                                  : () => onSelect(
                                                      app.packageName,
                                                    ),
                                            ),
                                          ),
                                        // Last, as on the sheet: one tap on an installed app is strictly
                                        // faster, so the QR must never read as the recommendation.
                                        if (apps.isNotEmpty)
                                          UpiQrOptionRow(
                                            identifier:
                                                'arul_return_upi_option_qr',
                                            selected: selection == kUpiPickQr,
                                            showTick: true,
                                            onTap: busy
                                                ? null
                                                : () => onSelect(kUpiPickQr),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // A row running under the pinned button fades out rather than being cut by a
                      // hard edge — the ground's own cream at alpha 0, never `Colors.transparent`,
                      // which is transparent BLACK and greys the lerp (ui-direction.md).
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 20,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  ArulTokens.paywallCream.withValues(alpha: 0),
                                  ArulTokens.paywallCream,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    24,
                    12,
                    24,
                    ArulTokens.paywallFooterBottomPadding,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShrineCta(
                        label: l10n.premiumCtaTrial,
                        busy: busy,
                        onPressed: busy ? null : onStart,
                      ),
                      const SizedBox(height: 12),
                      const PaywallOrnamentImage(
                        ornament: PaywallOrnament.footerRule,
                        width: ArulTokens.paywallFooterRuleWidth,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
