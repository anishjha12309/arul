import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/features/wallpapers/presentation/feed_card_geometry.dart';

/// The reel card's size has been rewritten several times, so these pin it to
/// actual numbers on actual devices rather than trusting the formula to stay
/// right by inspection.
///
/// The shape is a product decision (short, wide, generous air — see the class
/// doc). Anything that moves these numbers is either a deliberate re-decision or
/// a regression; there is no third case.
void main() {
  /// Arul's top chrome: header 48 + chips 34 + chipsGap 10 + divider 1 +
  /// reelTopGap 14. Modelled here as the reel height the LayoutBuilder hands in,
  /// so a change to the header shows up as a floor change, never a card one.
  double reelHeightFor({
    required double screenHeight,
    required double statusBar,
    required double bottomInset,
  }) => screenHeight - statusBar - bottomInset - 107;

  group('on a 1080x2400 phone', () {
    // 392.7 x 872.7 dp at dpr 2.75, 24dp status bar, gesture nav.
    const screen = Size(392.7, 872.7);
    final reel = reelHeightFor(
      screenHeight: screen.height,
      statusBar: 24,
      bottomInset: 16,
    );
    final geo = FeedCardGeometry.solve(screen: screen, reelHeight: reel);

    test('the card is 353 x 656, at 1:1.86', () {
      expect(geo.size.width, closeTo(352.7, 0.5));
      expect(geo.size.height, closeTo(656, 1));
      expect(geo.size.height / geo.size.width, closeTo(1.86, 0.01));
    });

    test('gutters are 20 and there is no vertical margin', () {
      expect(geo.margin.left, 20);
      expect(geo.margin.right, 20);
      // The gap belongs to the page, not the card.
      expect(geo.margin.top, 0);
      expect(geo.margin.bottom, 0);
    });

    test('the card eats the reel: peek clamps down, floor is zero', () {
      // targetPeek is 168, but the card leaves nowhere near that. The clamp
      // giving the space back to the peek — not to a floor — is the whole
      // reason this shape reads as full-bleed rather than framed.
      expect(geo.peek, lessThan(FeedCardGeometry.targetPeek));
      expect(geo.peek, closeTo(56, 1.5));
      expect(geo.peek, greaterThan(FeedCardGeometry.minPeek));
      expect(geo.floor, closeTo(0, 0.01));
    });

    test('card + gap + peek + floor exactly fills the reel', () {
      expect(
        geo.size.height + FeedCardGeometry.gap + geo.peek + geo.floor,
        closeTo(reel, 0.01),
        reason: 'a mismatch means dead space, or a card clipped by the pager',
      );
    });

    test('the pager gets the reel minus the floor', () {
      expect(geo.pagerHeight(reel), closeTo(reel - geo.floor, 0.01));
      // …and card + gap + peek fills exactly that, which is what makes the
      // viewportFraction land the peek where it is supposed to.
      expect(
        geo.size.height + FeedCardGeometry.gap + geo.peek,
        closeTo(geo.pagerHeight(reel), 0.01),
      );
    });

    test('page extent is card + gap', () {
      expect(geo.pageExtent, geo.size.height + FeedCardGeometry.gap);
    });
  });

  group('the crop is understood, not accidental', () {
    const source = 16 / 9; // 1.778

    test('a 1:1.86 card trims ~4.4% off the SIDES, nothing off the top', () {
      // Taller than the source: cover matches HEIGHT and overflows width, so the
      // loss is horizontal — the cheap direction. Crowns and feet survive.
      expect(FeedCardGeometry.cardAspect, greaterThan(source));
      const crop = 1 - source / FeedCardGeometry.cardAspect;
      expect(crop, closeTo(0.044, 0.005));
    });

    test('1.78 is the boundary the crop flips at', () {
      // Below it the loss moves to top/bottom and gets expensive fast, which is
      // what ViewerMedia.cropAlignment's upward bias exists for. Anyone lowering
      // cardAspect needs to know they have crossed a line, not nudged a dial.
      expect(source, closeTo(1.778, 0.001));
    });
  });

  group('short screens degrade in the right order', () {
    // 720x1280 / dpr 2 = 360x640 dp, the narrowest screen worth supporting.
    const small = Size(360, 640);
    final smallReel = reelHeightFor(
      screenHeight: small.height,
      statusBar: 24,
      bottomInset: 16,
    );

    test('the floor goes first — and at this aspect it is already zero', () {
      // A 1:1.86 card consumes nearly the whole reel on ANY phone, so the floor
      // is dormant across the real device range and only reappears if cardAspect
      // is lowered. That is a property of the chosen shape, not a bug.
      final geo = FeedCardGeometry.solve(screen: small, reelHeight: smallReel);
      expect(geo.floor, 0);
    });

    test('then the peek, down to minPeek — never below it', () {
      final geo = FeedCardGeometry.solve(screen: small, reelHeight: smallReel);
      expect(geo.peek, greaterThanOrEqualTo(FeedCardGeometry.minPeek));
    });

    test('only then does the card give up height, and it never overflows', () {
      final geo = FeedCardGeometry.solve(screen: small, reelHeight: smallReel);
      expect(geo.peek, FeedCardGeometry.minPeek);
      expect(
        geo.size.height + FeedCardGeometry.gap + geo.peek,
        lessThanOrEqualTo(smallReel + 0.01),
        reason: 'a card taller than its own viewport cannot snap',
      );
    });

    test('a small screen ends up SQUARER than 9:16 — which is why the '
        'upward crop bias is kept', () {
      // The card cannot hold 1.86 in a 493dp reel, so it shortens to ~1.36 and
      // the crop flips to top/bottom. ViewerMedia.cropAlignment's y-bias is
      // dormant on a normal phone but live here, and removing it as "unused"
      // would silently start taking crowns off on exactly the budget devices
      // this app targets.
      final geo = FeedCardGeometry.solve(screen: small, reelHeight: smallReel);
      final aspect = geo.size.height / geo.size.width;
      expect(aspect, lessThan(16 / 9));
      expect(aspect, closeTo(1.36, 0.05));
    });
  });

  group('degenerate frames never produce negative sizes', () {
    test('a zero-height reel', () {
      final geo = FeedCardGeometry.solve(
        screen: const Size(392.7, 872.7),
        reelHeight: 0,
      );
      expect(geo.size.height, greaterThanOrEqualTo(0));
      expect(geo.peek, greaterThanOrEqualTo(0));
      expect(geo.floor, greaterThanOrEqualTo(0));
    });

    test('a screen narrower than the gutters', () {
      final geo = FeedCardGeometry.solve(
        screen: const Size(20, 400),
        reelHeight: 200,
      );
      expect(geo.size.width, greaterThanOrEqualTo(0));
    });
  });

  group('the action row fits inside the card', () {
    test('pill floor + gap + circle clears the gutters on a small phone', () {
      final geo = FeedCardGeometry.solve(
        screen: const Size(360, 640),
        reelHeight: 480,
      );
      final rowWidth = geo.size.width - FeedCardGeometry.actionInset * 2;
      // _ApplyPill minWidth 168 + 12 spacer + a 52 Share circle.
      expect(
        rowWidth,
        greaterThanOrEqualTo(168 + 12 + 52),
        reason: 'the Apply pill would be squeezed below its floor',
      );
    });
  });
}
