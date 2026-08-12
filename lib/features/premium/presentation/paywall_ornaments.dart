import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/arul_tokens.dart';

/// The shared cream-and-temple ground for every premium surface.
class PaywallGround extends StatelessWidget {
  const PaywallGround({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: ArulTokens.paywallCream,
    child: Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(child: PaywallBackgroundPlate()),
        MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: child),
      ],
    ),
  );
}

/// Generated illustrations used by the premium paywall's ornament layer.
enum PaywallOrnament {
  floret,
  floretGold,
  lotus,
  gopuram,
  priceDivider,
  footerRule,
  wallpapers,
  ringtones,
  daily,
}

extension on PaywallOrnament {
  String get assetPath => switch (this) {
    PaywallOrnament.floret => 'assets/premium/ornament_floret.png',
    PaywallOrnament.floretGold => 'assets/premium/ornament_floret_gold.png',
    PaywallOrnament.lotus => 'assets/premium/ornament_lotus.png',
    PaywallOrnament.gopuram => 'assets/premium/ornament_gopuram.png',
    PaywallOrnament.priceDivider => 'assets/premium/ornament_price_divider.png',
    PaywallOrnament.footerRule => 'assets/premium/ornament_footer_rule.png',
    PaywallOrnament.wallpapers => 'assets/premium/medallion_wallpapers.png',
    PaywallOrnament.ringtones => 'assets/premium/medallion_ringtones.png',
    PaywallOrnament.daily => 'assets/premium/medallion_daily.png',
  };
}

/// A decorative PNG that never enters the semantics tree.
class PaywallOrnamentImage extends StatelessWidget {
  const PaywallOrnamentImage({
    super.key,
    required this.ornament,
    required this.width,
    this.color,
    this.colorBlendMode,
  });

  final PaywallOrnament ornament;
  final double width;
  final Color? color;
  final BlendMode? colorBlendMode;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Image.asset(
        ornament.assetPath,
        width: width,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        color: color,
        colorBlendMode: color == null
            ? null
            : colorBlendMode ?? BlendMode.srcIn,
      ),
    );
  }
}

/// The full-bleed line-art plate, decoded to its actual display width.
class PaywallBackgroundPlate extends StatelessWidget {
  const PaywallBackgroundPlate({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final cacheWidth = math.max(
          1,
          (constraints.maxWidth * devicePixelRatio).ceil(),
        );

        return ExcludeSemantics(
          child: IgnorePointer(
            child: Opacity(
              opacity: ArulTokens.paywallOrnamentAlpha,
              child: Image.asset(
                'assets/premium/bg_plate.png',
                fit: BoxFit.cover,
                alignment: Alignment.center,
                cacheWidth: cacheWidth,
                filterQuality: FilterQuality.medium,
                isAntiAlias: true,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A fading rule joined to a floret, mirrored around nearby copy when needed.
class PaywallOrnamentWing extends StatelessWidget {
  const PaywallOrnamentWing({
    super.key,
    required this.ruleWidth,
    required this.floretSize,
    required this.gap,
    this.mirrored = false,
  });

  final double ruleWidth;
  final double floretSize;
  final double gap;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    const gradient = ArulTokens.paywallBrandRule;
    final rule = SizedBox(
      width: ruleWidth,
      height: ArulTokens.paywallOrnamentRuleThickness,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: mirrored
              ? LinearGradient(
                  begin: gradient.end,
                  end: gradient.begin,
                  colors: gradient.colors,
                )
              : gradient,
        ),
      ),
    );
    final floret = PaywallOrnamentImage(
      ornament: PaywallOrnament.floret,
      width: floretSize,
    );
    final spacer = SizedBox(width: gap);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: mirrored ? [floret, spacer, rule] : [rule, spacer, floret],
    );
  }
}

/// Florets, rules and a small gopuram separating proof from the brand.
class PaywallTempleDivider extends StatelessWidget {
  const PaywallTempleDivider({super.key});

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(width: ArulTokens.paywallTempleDividerGap);
    const floret = PaywallOrnamentImage(
      ornament: PaywallOrnament.floret,
      width: ArulTokens.paywallTempleDividerFloretSize,
    );
    const rule = SizedBox(
      height: ArulTokens.paywallOrnamentRuleThickness,
      child: ColoredBox(color: ArulTokens.paywallGold700),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArulTokens.paywallTempleDividerInset,
      ),
      child: Row(
        children: [
          floret,
          gap,
          const Expanded(child: rule),
          gap,
          const PaywallOrnamentImage(
            ornament: PaywallOrnament.gopuram,
            width: ArulTokens.paywallTempleDividerGopuramSize,
          ),
          gap,
          const Expanded(child: rule),
          gap,
          floret,
        ],
      ),
    );
  }
}

/// Live text framed by the same lotus illustration on both sides.
class PaywallLotusLabel extends StatelessWidget {
  const PaywallLotusLabel({
    super.key,
    required this.child,
    required this.lotusSize,
    required this.gap,
  });

  final Widget child;
  final double lotusSize;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final lotus = PaywallOrnamentImage(
      ornament: PaywallOrnament.lotus,
      width: lotusSize,
    );
    final spacer = SizedBox(width: gap);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [lotus, spacer, child, spacer, lotus],
    );
  }
}

/// Live text framed by short gold rules.
class PaywallRuledLabel extends StatelessWidget {
  const PaywallRuledLabel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const rule = SizedBox(
      width: ArulTokens.paywallPriceCaptionRuleWidth,
      height: ArulTokens.paywallOrnamentRuleThickness,
      child: ColoredBox(color: ArulTokens.paywallGold600),
    );
    const gap = SizedBox(width: ArulTokens.paywallPriceCaptionRuleGap);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [rule, gap, child, gap, rule],
    );
  }
}

/// A gradient panel clipped to, and framed by, two parallel chamfered rules.
class PaywallChamferedPanel extends StatelessWidget {
  const PaywallChamferedPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: const _PaywallChamferedFramePainter(),
      child: ClipPath(
        clipper: const _PaywallChamferedClipper(),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: ArulTokens.paywallPanelFill,
          ),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

/// Lotus and dotted leaders laid over the top edge of the shrine panel.
class PaywallPanelCrown extends StatelessWidget {
  const PaywallPanelCrown({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ArulTokens.paywallPanelCrownInset,
      ),
      child: Row(
        children: [
          const Expanded(
            child: SizedBox(
              height: ArulTokens.paywallPanelCrownSize,
              child: PaywallDottedLine(),
            ),
          ),
          const SizedBox(width: ArulTokens.paywallPanelCrownGap),
          ColoredBox(
            color: ArulTokens.paywallCream,
            child: const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: ArulTokens.paywallPanelCrownBackdrop,
              ),
              child: PaywallOrnamentImage(
                ornament: PaywallOrnament.lotus,
                width: ArulTokens.paywallPanelCrownSize,
              ),
            ),
          ),
          const SizedBox(width: ArulTokens.paywallPanelCrownGap),
          const Expanded(
            child: SizedBox(
              height: ArulTokens.paywallPanelCrownSize,
              child: PaywallDottedLine(),
            ),
          ),
        ],
      ),
    );
  }
}

/// A code-drawn dotted rule that can run horizontally or vertically.
class PaywallDottedLine extends StatelessWidget {
  const PaywallDottedLine({super.key, this.vertical = false});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _PaywallDottedLinePainter(vertical: vertical));
  }
}

Path _chamferedPath(
  Size size, {
  required double inset,
  required double chamfer,
}) {
  final left = inset;
  final top = inset;
  final right = math.max(left, size.width - inset);
  final bottom = math.max(top, size.height - inset);
  final usableChamfer = math.min(
    chamfer,
    math.min((right - left) / 2, (bottom - top) / 2),
  );

  return Path()
    ..moveTo(left + usableChamfer, top)
    ..lineTo(right - usableChamfer, top)
    ..lineTo(right, top + usableChamfer)
    ..lineTo(right, bottom - usableChamfer)
    ..lineTo(right - usableChamfer, bottom)
    ..lineTo(left + usableChamfer, bottom)
    ..lineTo(left, bottom - usableChamfer)
    ..lineTo(left, top + usableChamfer)
    ..close();
}

class _PaywallChamferedClipper extends CustomClipper<Path> {
  const _PaywallChamferedClipper();

  @override
  Path getClip(Size size) =>
      _chamferedPath(size, inset: 0, chamfer: ArulTokens.paywallPanelChamfer);

  @override
  bool shouldReclip(_PaywallChamferedClipper oldClipper) => false;
}

class _PaywallChamferedFramePainter extends CustomPainter {
  const _PaywallChamferedFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = ArulTokens.paywallPanelFrameStroke;
    const halfStroke = stroke / 2;
    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = ArulTokens.paywallGold700;
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = ArulTokens.paywallGoldSoft;

    canvas.drawPath(
      _chamferedPath(
        size,
        inset: halfStroke,
        chamfer: ArulTokens.paywallPanelChamfer,
      ),
      outer,
    );
    canvas.drawPath(
      _chamferedPath(
        size,
        inset: ArulTokens.paywallPanelInnerInset + halfStroke,
        chamfer: ArulTokens.paywallPanelInnerChamfer,
      ),
      inner,
    );
  }

  @override
  bool shouldRepaint(_PaywallChamferedFramePainter oldDelegate) => false;
}

class _PaywallDottedLinePainter extends CustomPainter {
  const _PaywallDottedLinePainter({required this.vertical});

  final bool vertical;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ArulTokens.paywallDottedGold
      ..strokeWidth = ArulTokens.paywallOrnamentRuleThickness
      ..strokeCap = StrokeCap.round;
    const dash = ArulTokens.paywallDottedDash;
    const step = dash + ArulTokens.paywallDottedGap;
    final length = vertical ? size.height : size.width;

    for (double start = 0; start < length; start += step) {
      final end = math.min(start + dash, length);
      if (vertical) {
        canvas.drawLine(
          Offset(size.width / 2, start),
          Offset(size.width / 2, end),
          paint,
        );
      } else {
        canvas.drawLine(
          Offset(start, size.height / 2),
          Offset(end, size.height / 2),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PaywallDottedLinePainter oldDelegate) =>
      oldDelegate.vertical != vertical;
}
