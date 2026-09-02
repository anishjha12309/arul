import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/features/wallpapers/presentation/feed_card_geometry.dart';

/// `FeedCardGeometry` is a pure function of the screen and the reel -> the cheapest place to catch a knob moving.
/// The shape is a product decision, Shubh's tile numbers on Arul's reel -> see the class doc.
/// Anything that moves these numbers is a deliberate re-decision or a regression -> there is no third case.
void main() {
  /// The reel height the feed's LayoutBuilder hands in, modelled from a MEASURED frame, never summed from tokens.
  /// On a 411.4x911.2 dp phone with a 48 dp status bar and 24 dp gesture inset the card's top edge sat at 435 px.
  /// That is 118 dp of chrome below the status bar (title row + chips), with the reel's bottom 76 dp above the inset.
  /// The previous model (107 dp of chrome, nothing below) predicted a 682 dp card where the phone showed 601.
  double reelHeightFor({
    required double screenHeight,
    required double statusBar,
    required double bottomInset,
  }) => screenHeight - statusBar - 118 - 76 - bottomInset;

  group('on the Nothing A001 — the Shubh reference phone', () {
    // 1080x2392 at dpr 2.625 -> 411.43 x 911.24 dp.
    const dpr = 2.625;
    const screen = Size(1080 / dpr, 2392 / dpr);
    final reel = reelHeightFor(
      screenHeight: screen.height,
      statusBar: 48,
      bottomInset: 24,
    );
    final geo = FeedCardGeometry.solve(screen: screen, reelHeight: reel);

    test('the card is the size of Shubh\'s tile on the same phone', () {
      // Shubh, measured from its accessibility tree on this phone -> the pager runs 441..2160 px (1719).
      // A page is 0.95 of that (1633) and the tile is the page minus 8 dp (21 px) top and bottom -> 996 x 1591 px.
      const shubhTileWidthPx = 1080 - 2 * 16 * dpr; // 996
      const shubhTileHeightPx = 0.95 * 1719 - 2 * 8 * dpr; // 1591
      expect(geo.size.width * dpr, closeTo(shubhTileWidthPx, 1));
      // By hand: reel = 911.24 - 48 - 118 - 76 - 24 = 645.24 -> the card gets 645.24 - 16 - 25 = 604.24 dp = 1586 px.
      // Within 2 dp of Shubh's 1591.
      expect(geo.size.height * dpr, closeTo(shubhTileHeightPx, 2 * dpr));
    });

    test('gutters are 16 and there is no vertical margin', () {
      expect(geo.margin.left, 16);
      expect(geo.margin.right, 16);
      // The gap belongs to the page, not the card.
      expect(geo.margin.top, 0);
      expect(geo.margin.bottom, 0);
    });

    test('the card eats the reel: peek pinned at minPeek, floor is zero', () {
      expect(geo.peek, lessThan(FeedCardGeometry.targetPeek));
      expect(geo.peek, FeedCardGeometry.minPeek);
      expect(geo.floor, closeTo(0, 0.01));
    });

    test('the card is height-clamped, not aspect-driven, on this phone', () {
      // `width * cardAspect` does not fit -> the solver hands back what is left after the gap and the minimum peek.
      // That is what makes `gutter` a width-only knob.
      expect(
        geo.size.width * FeedCardGeometry.cardAspect,
        greaterThan(geo.size.height),
        reason: 'if this stops being true, gutter starts buying height again',
      );
      expect(
        geo.size.height,
        closeTo(reel - FeedCardGeometry.gap - FeedCardGeometry.minPeek, 0.01),
      );
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
      expect(
        geo.size.height + FeedCardGeometry.gap + geo.peek,
        closeTo(geo.pagerHeight(reel), 0.01),
      );
    });

    test('page extent is card + gap', () {
      expect(geo.pageExtent, geo.size.height + FeedCardGeometry.gap);
    });
  });

  group('on a 1080x2400 phone', () {
    // 392.7 x 872.7 dp at dpr 2.75, 24dp status bar, gesture nav.
    const screen = Size(392.7, 872.7);
    final reel = reelHeightFor(
      screenHeight: screen.height,
      statusBar: 24,
      bottomInset: 16,
    );
    final geo = FeedCardGeometry.solve(screen: screen, reelHeight: reel);

    test('the card is 361 x 598, at ~1:1.66', () {
      // By hand: width = 392.7 - 2x16 = 360.7; reel = 872.7 - 24 - 118 - 76 - 16 = 638.7.
      // The requested 360.7 x 1.86 = 670.9 does not fit -> height = 638.7 - 16 - 25 = 597.7.
      expect(geo.size.width, closeTo(360.7, 0.5));
      expect(geo.size.height, closeTo(597.7, 1));
      expect(geo.size.height / geo.size.width, closeTo(1.66, 0.01));
      expect(geo.peek, FeedCardGeometry.minPeek);
      expect(geo.floor, closeTo(0, 0.01));
    });
  });

  group('the crop is understood, not accidental', () {
    const source = 16 / 9; // 1.778

    test('the REALISED card is squarer than 9:16, so the trim is top/bottom', () {
      // Shubh's tile is shorter than the artwork on every ordinary phone -> `cover` matches WIDTH and overflows height.
      // That is ~7% on a 1080x2400 and ~10% on a 411x911 -> the expensive direction for devotional art.
      // So ViewerMedia.cropAlignment's upward bias must stay -> it is LIVE, not dormant, and keeps the trim off the crown.
      final tall = FeedCardGeometry.solve(
        screen: const Size(392.7, 872.7),
        reelHeight: reelHeightFor(
          screenHeight: 872.7,
          statusBar: 24,
          bottomInset: 16,
        ),
      );
      final aspect = tall.size.height / tall.size.width;
      expect(aspect, lessThan(source));
      // By hand: 1 − 1.657 / 1.778 = 0.068.
      expect(1 - aspect / source, closeTo(0.068, 0.005));
    });

    test('the card still ASKS for a taller-than-source shape', () {
      // The reel squeezes it, but the request stays on the safe side of the boundary.
      // On a screen tall enough to grant it, the crop is horizontal.
      expect(FeedCardGeometry.cardAspect, greaterThan(source));
    });

    test('1.78 is the boundary the crop flips at', () {
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

    test('a small screen ends up far SQUARER than 9:16 — the upward crop '
        'bias earns its keep here', () {
      // By hand: reel 640 - 24 - 118 - 76 - 16 = 406; height 406 - 16 - 25 = 365 over width 360 - 32 = 328 -> 1.11.
      final geo = FeedCardGeometry.solve(screen: small, reelHeight: smallReel);
      final aspect = geo.size.height / geo.size.width;
      expect(aspect, lessThan(16 / 9));
      expect(aspect, closeTo(1.11, 0.05));
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
