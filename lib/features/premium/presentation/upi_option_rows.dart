import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/upi/upi_apps.dart';
import '../../../theme/arul_tokens.dart';

/// What the picker pops for its QR row, in place of a package name.
///
/// A sentinel rather than a package because the QR is not one: it names PhonePe's package only to
/// satisfy PhonePe's mandatory `targetApp`, and letting that name come back through the picker would
/// write PhonePe into the remembered-app pref and make the next visit's CTA silently launch an app
/// the user never chose. The return page's QR row selects this same value.
/// Shaped so no real package can collide with it — a package name has no leading `#`.
const kUpiPickQr = '#qr';

/// One UPI app as a row — drawn by the "Pay using" sheet AND by the return page, from this one
/// widget, so the two can never drift apart. Built so no translation can overflow it.
///
/// The overflow matrix demotes an overflowing KEY to English everywhere -> on this screen that is
/// all-or-nothing, so the row has to be safe by
/// CONSTRUCTION rather than by measurement. Three rules do it: the icon is fixed and sits outside
/// the flexible column, name and badge share a `Wrap` so a long locale drops the badge to its own
/// line instead of pushing the row over, and every text is capped to the row's OWN constraints.
class UpiOptionRow extends StatelessWidget {
  const UpiOptionRow({
    super.key,
    required this.app,
    required this.selected,
    required this.lastUsed,
    required this.onTap,
    required this.identifier,
    this.showTick = false,
  });

  final UpiApp app;
  final bool selected;
  final bool lastUsed;

  /// Null while the page is busy — the row still shows, and answers nothing.
  final VoidCallback? onTap;

  /// Stable accessibility id (`Semantics(identifier:)`): announced to nobody, so it is free at
  /// the UI layer and survives every locale.
  /// Never announced and never visible — see that folder's README for the list.
  final String identifier;

  /// The return page's tick. On the sheet a tap IS the choice and closes it, so a tick there would
  /// promise a second step that never comes; on the page a tap only selects, and the button below
  /// acts — so the choice has to stay visible after the finger lifts.
  final bool showTick;

  @override
  Widget build(BuildContext context) {
    return _OptionShell(
      identifier: identifier,
      label: app.label,
      selected: selected,
      showTick: showTick,
      onTap: onTap,
      leading: UpiAppIcon(app: app, size: 44),
      body: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // The label is the OS's own, already in the user's locale -> never an ARB key.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: Text(
                app.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ArulTokens.paywallUpiName.copyWith(
                  fontSize: 14.5,
                  height: 1.25,
                  color: selected
                      ? ArulTokens.paywallMaroon
                      : ArulTokens.paywallInkUpi,
                ),
              ),
            ),
            if (lastUsed)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: const _LastUsedBadge(),
              ),
          ],
        ),
      ),
    );
  }
}

/// The QR row at the foot of the app list — [UpiOptionRow]'s shape without an app behind it.
///
/// Built to the same overflow rules as that row, because the same all-or-nothing English demotion
/// applies: the glyph is fixed and outside the flexible column, and both texts are capped to the
/// row's own constraints. On the sheet it is never `selected`: nothing is remembered there, so there
/// is no state to show, and a gold border would claim the CTA is about to do this. On the return page
/// it can be — there a tap only selects, and the button below is what acts on it.
class UpiQrOptionRow extends StatelessWidget {
  const UpiQrOptionRow({
    super.key,
    required this.onTap,
    required this.identifier,
    this.selected = false,
    this.showTick = false,
  });

  final VoidCallback? onTap;
  final String identifier;
  final bool selected;
  final bool showTick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _OptionShell(
      identifier: identifier,
      label: l10n.upiPickerQrTitle,
      selected: selected,
      showTick: showTick,
      onTap: onTap,
      // Sized to the app icons beside it so the column of glyphs stays a straight line.
      leading: const SizedBox.square(
        dimension: 44,
        child: Icon(
          Icons.qr_code_2_rounded,
          size: 32,
          color: ArulTokens.paywallGoldDeep,
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: Text(
                l10n.upiPickerQrTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ArulTokens.paywallUpiName.copyWith(
                  fontSize: 14.5,
                  height: 1.25,
                  color: selected
                      ? ArulTokens.paywallMaroon
                      : ArulTokens.paywallInkUpi,
                ),
              ),
            ),
            const SizedBox(height: 2),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: Text(
                l10n.upiPickerQrSubtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ArulTokens.paywallUpiName.copyWith(
                  fontSize: 12,
                  height: 1.3,
                  color: ArulTokens.paywallInkUpi.withValues(alpha: 0.62),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame both rows share: border, selected fill, press-down tick, and the optional radio tick.
class _OptionShell extends StatelessWidget {
  const _OptionShell({
    required this.identifier,
    required this.label,
    required this.selected,
    required this.showTick,
    required this.onTap,
    required this.leading,
    required this.body,
  });

  final String identifier;
  final String label;
  final bool selected;
  final bool showTick;
  final VoidCallback? onTap;
  final Widget leading;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    return Semantics(
      container: true,
      identifier: identifier,
      label: label,
      button: true,
      selected: selected,
      enabled: tap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: tap == null ? null : (_) => ArulHaptics.tap(),
        onTap: tap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected
                ? ArulTokens.paywallMedallionFill
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? ArulTokens.paywallGold600
                  : ArulTokens.paywallBorderSoft,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Padding(
            // Compensates the thicker selected border -> the icon never shifts between states.
            padding: EdgeInsets.all(selected ? 10.5 : 11),
            child: Row(
              children: [
                // Never shrinks: the launcher icon is the row's recognition cue and the only
                // locale-invariant thing in it -> everything else reflows around it.
                leading,
                const SizedBox(width: 13),
                Expanded(child: body),
                if (showTick) ...[
                  const SizedBox(width: 10),
                  _Tick(on: selected),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A radio in the paywall's gold: a ring when off, a filled disc with a check when on.
class _Tick extends StatelessWidget {
  const _Tick({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? ArulTokens.paywallGold600 : Colors.transparent,
        border: on
            ? null
            : Border.all(color: ArulTokens.paywallBorderControl, width: 1.5),
      ),
      child: on
          ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
          : null,
    );
  }
}

/// "Last used" — the remembered pick made visible, so a returning user can see we kept it.
class _LastUsedBadge extends StatelessWidget {
  const _LastUsedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ArulTokens.paywallBorderPill),
      ),
      child: Text(
        AppLocalizations.of(context).upiPickerLastUsed,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ArulTokens.paywallPill.copyWith(
          fontSize: 9.5,
          height: 1.2,
          letterSpacing: 0.95,
          color: ArulTokens.paywallInkGold,
        ),
      ),
    );
  }
}

/// App icon from PackageManager bytes, or the wallet glyph fallback.
class UpiAppIcon extends StatelessWidget {
  const UpiAppIcon({super.key, required this.app, required this.size});

  final UpiApp app;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = app.icon;
    if (icon == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Icon(
          Icons.account_balance_wallet_outlined,
          size: size - 12,
          color: ArulTokens.paywallGoldDeep,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.memory(
        icon,
        width: size,
        height: size,
        gaplessPlayback: true,
      ),
    );
  }
}
