import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../theme/arul_tokens.dart';
import '../domain/cancel_offer.dart';
import 'member_view.dart';
import 'paywall_ornaments.dart';
import 'paywall_view.dart';

/// How a cancel-offer sheet closed: `accept` only once the switch was handed off, `decline` = "I
/// don't want the offer", `close` = the X. Back, scrim and drag answer null.
enum CancelOfferChoice { accept, decline, close }

/// Picks the UPI route and starts the ₹99 switch; false when nothing started (the picker was closed).
typedef CancelOfferStart = Future<bool> Function();

/// The hold's clock; tests point it at the fake one.
@visibleForTesting
DateTime Function() cancelOfferClock = DateTime.now;

/// The ₹99 save offer, the first thing a Cancel tap opens. No way out of it cancels anything.
Future<CancelOfferChoice?> showCancelOfferSheet(
  BuildContext context, {
  required String offerPrice,
  required CancelOfferStart onAccept,
  required Future<void> Function() untilHandedOff,
  VoidCallback? onExpired,
}) => showArulSheet<CancelOfferChoice>(
  context,
  // The paywall's own ground, like every sheet /premium opens.
  surfaceColor: ArulTokens.paywallCream,
  builder: (_) => _CancelOfferBody(
    offerPrice: offerPrice,
    onAccept: onAccept,
    untilHandedOff: untilHandedOff,
    onExpired: onExpired,
  ),
);

/// After a switch that did not go through; null = back or scrim, which must change nothing.
Future<CancelOfferChoice?> showCancelOfferRetrySheet(
  BuildContext context, {
  required String reason,
  required CancelOfferStart onRetry,
  required Future<void> Function() untilHandedOff,
}) => showArulSheet<CancelOfferChoice>(
  context,
  surfaceColor: ArulTokens.paywallCream,
  enableDrag: false,
  builder: (_) => _CancelOfferRetryBody(
    reason: reason,
    onRetry: onRetry,
    untilHandedOff: untilHandedOff,
  ),
);

// Closes as `accept` only after the handoff: the screen's purchase listener owns everything after.
mixin _SwitchStarter<T extends StatefulWidget> on State<T> {
  // The picker is up or the initiate is running: no second start, and no leaving mid-initiate.
  bool _starting = false;

  bool _busy = false;

  Future<void> _start(
    CancelOfferStart start,
    Future<void> Function() untilHandedOff,
  ) async {
    if (_starting) return;
    setState(() => _starting = true);
    var handedOff = false;
    try {
      final started = await start();
      if (!started || !mounted) return;
      setState(() => _busy = true);
      await untilHandedOff();
      handedOff = true;
      _close(CancelOfferChoice.accept);
    } finally {
      // A closing sheet keeps its spinner through the exit rather than flash the idle label.
      if (mounted && !handedOff) {
        setState(() {
          _starting = false;
          _busy = false;
        });
      }
    }
  }

  void _close(CancelOfferChoice? choice) {
    if (!mounted) return;
    final route = ModalRoute.of<CancelOfferChoice>(context);
    final navigator = Navigator.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(choice);
    } else if (route.isActive) {
      // Something opened above the sheet meanwhile; a plain pop would close that instead.
      navigator.removeRoute(route, choice);
    }
  }
}

// The member view's ground under a sheet: the temple plate over cream, text clamped as there.
class _SheetGround extends StatelessWidget {
  const _SheetGround({required this.child, this.top = 18});

  final Widget child;
  final double top;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      const Positioned.fill(child: PaywallBackgroundPlate()),
      MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            ArulTokens.premiumMemberPageInset,
            top,
            ArulTokens.premiumMemberPageInset,
            14,
          ),
          child: child,
        ),
      ),
    ],
  );
}

// The plan hero's crest: gold rule, floret, gopuram, floret, rule.
class _Crest extends StatelessWidget {
  const _Crest();

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      PaywallOrnamentWing(
        ruleWidth: ArulTokens.premiumMemberHeroRuleWidth,
        floretSize: ArulTokens.premiumMemberHeroFloretSize,
        gap: ArulTokens.premiumMemberHeroOrnamentGap,
      ),
      SizedBox(width: ArulTokens.premiumMemberHeroOrnamentGap),
      PaywallOrnamentImage(ornament: PaywallOrnament.gopuram, width: 46),
      SizedBox(width: ArulTokens.premiumMemberHeroOrnamentGap),
      PaywallOrnamentWing(
        ruleWidth: ArulTokens.premiumMemberHeroRuleWidth,
        floretSize: ArulTokens.premiumMemberHeroFloretSize,
        gap: ArulTokens.premiumMemberHeroOrnamentGap,
        mirrored: true,
      ),
    ],
  );
}

class _CancelOfferBody extends StatefulWidget {
  const _CancelOfferBody({
    required this.offerPrice,
    required this.onAccept,
    required this.untilHandedOff,
    required this.onExpired,
  });

  final String offerPrice;
  final CancelOfferStart onAccept;
  final Future<void> Function() untilHandedOff;
  final VoidCallback? onExpired;

  @override
  State<_CancelOfferBody> createState() => _CancelOfferBodyState();
}

class _CancelOfferBodyState extends State<_CancelOfferBody>
    with _SwitchStarter {
  late final DateTime _deadline = cancelOfferClock().add(kCancelOfferHold);

  bool _expired = false;

  void _leave(CancelOfferChoice choice) {
    if (_starting) return;
    _close(choice);
  }

  void _expire() {
    if (!mounted) return;
    setState(() => _expired = true);
    widget.onExpired?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_starting,
      child: _SheetGround(
        top: 4,
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  // Clears the X on both sides, so the title stays centred on the sheet.
                  padding: const EdgeInsets.fromLTRB(
                    ArulTokens.minHitTarget,
                    12,
                    ArulTokens.minHitTarget,
                    0,
                  ),
                  child: Text(
                    l10n.cancelOfferTitle,
                    textAlign: TextAlign.center,
                    style: ArulTokens.premiumMemberHeadline,
                  ),
                ),
                const SizedBox(height: ArulTokens.premiumMemberSublineGap),
                Text(
                  l10n.cancelOfferSubtitle,
                  textAlign: TextAlign.center,
                  style: ArulTokens.paywallLead,
                ),
                const SizedBox(height: 18),
                Text(
                  l10n.cancelOfferDiscount,
                  textAlign: TextAlign.center,
                  style: ArulTokens.paywallWordmark,
                ),
                const SizedBox(height: 6),
                _OfferPrice(price: widget.offerPrice),
                const SizedBox(height: 6),
                Text(
                  l10n.cancelOfferBilling,
                  textAlign: TextAlign.center,
                  style: ArulTokens.premiumMemberBody.copyWith(fontSize: 14),
                ),
                const SizedBox(height: 16),
                Center(
                  child: _HoldPill(deadline: _deadline, onExpired: _expire),
                ),
                const SizedBox(height: 20),
                ShrineCta(
                  label: l10n.cancelOfferAccept,
                  busy: _busy,
                  bottomLotus: true,
                  onPressed: _starting || _expired
                      ? null
                      : () => _start(widget.onAccept, widget.untilHandedOff),
                ),
                const SizedBox(
                  height: ArulTokens.premiumCelebrateLotusClearance,
                ),
                TextButton(
                  key: const ValueKey('cancel-offer-decline'),
                  onPressed: _starting
                      ? null
                      : () => _leave(CancelOfferChoice.decline),
                  style: TextButton.styleFrom(
                    foregroundColor: ArulTokens.paywallInkSecondary,
                    minimumSize: const Size.fromHeight(ArulTokens.minHitTarget),
                  ),
                  child: Text(
                    l10n.cancelOfferDecline,
                    textAlign: TextAlign.center,
                    // Flutter has no underline offset: the glyphs paint as a shadow 3 px up, so
                    // the line sits clear of the descenders.
                    style: ArulTokens.premiumMemberBody.copyWith(
                      fontWeight: FontWeight.w500,
                      color: Colors.transparent,
                      shadows: const [
                        Shadow(
                          color: ArulTokens.paywallInkSecondary,
                          offset: Offset(0, -3),
                        ),
                      ],
                      decoration: TextDecoration.underline,
                      decorationColor: ArulTokens.paywallInkSecondary,
                    ),
                  ),
                ),
              ],
            ),
            PositionedDirectional(
              top: 4,
              end: -6,
              child: IconButton(
                key: const ValueKey('cancel-offer-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                color: ArulTokens.paywallInkSecondary,
                iconSize: 18,
                style: IconButton.styleFrom(
                  backgroundColor: ArulTokens.paywallMaroon.withValues(
                    alpha: 0.07,
                  ),
                  fixedSize: const Size.square(36),
                  minimumSize: const Size.square(36),
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.close),
                onPressed: _starting
                    ? null
                    : () => _leave(CancelOfferChoice.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// The amount carries the line; the period stays small, whichever side of it a language puts it.
class _OfferPrice extends StatelessWidget {
  const _OfferPrice({required this.price});

  final String price;

  @override
  Widget build(BuildContext context) {
    final line = AppLocalizations.of(context).cancelOfferPrice(price);
    final at = line.indexOf(price);
    // The owner wants the period as background noise: the smallest size that stays legible.
    const rest = TextStyle(
      fontFamily: ArulTokens.paywallTextFamily,
      fontFamilyFallback: ArulTokens.paywallSerifFallback,
      fontSize: 11,
      color: ArulTokens.paywallInkFaint,
    );
    return Text.rich(
      TextSpan(
        children: [
          if (at > 0) TextSpan(text: line.substring(0, at)),
          TextSpan(
            text: at < 0 ? line : price,
            style: const TextStyle(
              fontFamily: ArulTokens.paywallTextFamily,
              fontFamilyFallback: ArulTokens.paywallSerifFallback,
              fontWeight: FontWeight.w600,
              fontSize: 26,
              color: ArulTokens.paywallInk,
            ),
          ),
          if (at >= 0) TextSpan(text: line.substring(at + price.length)),
        ],
      ),
      textAlign: TextAlign.center,
      style: rest,
    );
  }
}

// The hold, counted down from the sheet's own deadline: a UPI app in front stops no clock.
class _HoldPill extends StatefulWidget {
  const _HoldPill({required this.deadline, required this.onExpired});

  final DateTime deadline;
  final VoidCallback onExpired;

  @override
  State<_HoldPill> createState() => _HoldPillState();
}

class _HoldPillState extends State<_HoldPill> {
  Timer? _tick;
  late int _secondsLeft = _remaining();

  int _remaining() {
    final left = widget.deadline.difference(cancelOfferClock());
    return left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _remaining();
      setState(() => _secondsLeft = left);
      if (left == 0) {
        _tick?.cancel();
        widget.onExpired();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ended = _secondsLeft == 0;
    final minutes = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsLeft % 60).toString().padLeft(2, '0');
    final ink = ended ? ArulTokens.paywallInkMuted : ArulTokens.paywallMaroon;
    final time = '$minutes:$seconds';
    final line = ended ? l10n.cancelOfferEnded : l10n.cancelOfferEndsIn(time);
    final at = ended ? -1 : line.indexOf(time);
    // One node read as a sentence; a live region only once it ends, so a screen reader hears
    // "Offer ended" when it happens instead of a fresh time every second.
    return Semantics(
      container: true,
      liveRegion: ended,
      label: line,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: ArulTokens.paywallGoldSoft.withValues(alpha: 0.3),
          border: Border.all(
            color: ArulTokens.paywallGold500.withValues(alpha: 0.6),
          ),
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ended ? Icons.timer_off_outlined : Icons.timer_outlined,
              size: 17,
              color: ink,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: at < 0
                      ? [TextSpan(text: line)]
                      : [
                          TextSpan(text: line.substring(0, at)),
                          // Fixed-width digits so the pill holds still; Lora's tnum widens its
                          // spaces too, so only the time carries it.
                          TextSpan(
                            text: time,
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          TextSpan(text: line.substring(at + time.length)),
                        ],
                ),
                textAlign: TextAlign.center,
                style: ArulTokens.paywallPill.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelOfferRetryBody extends StatefulWidget {
  const _CancelOfferRetryBody({
    required this.reason,
    required this.onRetry,
    required this.untilHandedOff,
  });

  final String reason;
  final CancelOfferStart onRetry;
  final Future<void> Function() untilHandedOff;

  @override
  State<_CancelOfferRetryBody> createState() => _CancelOfferRetryBodyState();
}

class _CancelOfferRetryBodyState extends State<_CancelOfferRetryBody>
    with _SwitchStarter {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_starting,
      child: _SheetGround(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Crest(),
            const SizedBox(height: ArulTokens.premiumMemberHeadlineGap),
            Text(
              l10n.cancelOfferRetryTitle,
              textAlign: TextAlign.center,
              style: ArulTokens.premiumMemberHeadline.copyWith(fontSize: 20),
            ),
            const SizedBox(height: ArulTokens.premiumMemberSublineGap),
            Text(
              widget.reason,
              textAlign: TextAlign.center,
              style: ArulTokens.premiumMemberBody,
            ),
            const SizedBox(height: 20),
            ShrineCta(
              label: l10n.cancelOfferTryAgain,
              busy: _busy,
              onPressed: _starting
                  ? null
                  : () => _start(widget.onRetry, widget.untilHandedOff),
            ),
            const SizedBox(height: 14),
            PremiumPlanCancelButton(
              busy: false,
              tapKey: 'cancel-offer-retry-cancel',
              onTap: _starting ? null : () => _close(CancelOfferChoice.decline),
            ),
          ],
        ),
      ),
    );
  }
}
