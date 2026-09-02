import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The resting size of one reel card, the peek below it, and the floor below that.
///
/// **Shubh's tile, on Arul's reel** (owner's call, `C:\prod-hsr-shubh` for the source).
/// Arul does not copy Shubh's 0.95 pager — it copies the NUMBERS it produces: gutter 16, gap 16,
/// minPeek 25, radius 24. The card is still solved from the reel.
/// The whole reel height is spoken for — `card + gap + peek + floor` — so growth costs one of them.
/// An ordinary phone consumes everything: floor zero, peek pinned to [minPeek] by [solve]'s clamps.
/// So the card is HEIGHT-CLAMPED on a real phone -> read the card's own size, never [cardAspect].
/// The catalog is 9:16, ratio 1:1.78.
/// A REALISED aspect taller than that trims left and right — the cheap direction for devotional art.
/// Below 1.78 the crop flips to top/bottom, and [ViewerMedia.cropAlignment]'s upward bias saves the crown.
/// Keep that bias — it is correct in BOTH directions.
///
/// Shapes already rejected, do not revisit:
///  * **the DEVICE aspect** (1:2.22) — a sliver that cropped ~20% off the sides;
///  * **Pakiza's card verbatim** (1:1.63, 18dp gutters) — too tall, too tight;
///  * **short and wide** (1:1.40, 32dp gutters) — 21% off top and bottom, the expensive direction.
///
/// Extracted from `feed_screen.dart` so it can be unit-tested directly.
/// Measuring a card through a full feed render is a slow, indirect way to catch a wrong number.
@immutable
class FeedCardGeometry {
  const FeedCardGeometry({
    required this.margin,
    required this.size,
    required this.peek,
    required this.floor,
  });

  /// Card margin, HORIZONTAL only — the card is flush with the top of the pager, dropped by [headroom].
  /// The gap below it belongs to the page (see [pageExtent]).
  final EdgeInsets margin;

  final Size size;

  /// How much of the NEXT card shows below this one.
  final double peek;

  /// Frame-coloured space left over once card, gap and peek are placed.
  ///
  /// SPLIT either side of the reel ([headroom]/[underhang]) -> the card is centred, not hung from top.
  /// Frequently ZERO: at [cardAspect] 1.86 the card consumes the whole reel on an ordinary phone.
  /// It earns its keep on tall screens, where the slack is real.
  final double floor;

  /// The half of [floor] that sits ABOVE the card.
  double get headroom => floor / 2;

  /// The half that stays below the peek — carries the odd pixel, so the reel cannot drift.
  double get underhang => floor - headroom;

  /// Side gutters — tight; the artwork carries the screen and the frame is breathing room, not a mount.
  ///
  /// **This is the WIDTH knob.** The card is height-clamped by the reel, so the gutter sets its width.
  /// And it moves the realised aspect as it goes.
  static const gutter = 16.0;

  /// Card height ÷ width — the aspect the card ASKS for.
  ///
  /// **The one number that controls the crop's direction.** 1.78 is exactly lossless.
  /// At 1.86 the card is taller than the artwork -> the trim is horizontal.
  /// An ordinary phone's reel cannot grant it -> read the card's own size, never this constant.
  /// Below 1.78 the crop flips to top/bottom and gets expensive fast — a boundary, not a slider.
  static const cardAspect = 1.86;

  /// Vertical gap between cards. It lives on the PAGE -> the extent solved for is card + gap.
  static const gap = 16.0;

  /// Card corner radius.
  static const radius = 24.0;

  /// Bottom scrim height, and the band the action row lives in.
  static const scrimHeight = 180.0;

  /// Inset of the Apply/Share row from the card's left, right and bottom edges.
  static const actionInset = 14.0;

  /// How much of the next card we aim to reveal — an AIM, not a promise.
  ///
  /// At [cardAspect] the card takes more than the whole reel -> a normal phone clamps to [minPeek].
  /// The generous value earns its keep on a tall screen, keeping the reel from ending in dead space.
  static const targetPeek = 168.0;

  /// The peek is squeezed to here before the CARD gives up any height.
  ///
  /// **This is the HEIGHT knob** — every dp off it goes straight into the card on a normal phone,
  /// where the peek is already pinned here.
  /// Never take it to zero: the sliver of the next wallpaper is why the reel reads as scrollable.
  static const minPeek = 25.0;

  /// The extent of one page — the card plus the gap that follows it.
  /// With `padEnds: false` the pager's `viewportFraction` resolves to this.
  /// So snap, drag and fling geometry stay a stock PageView's.
  double get pageExtent => size.height + gap;

  /// The height the PAGER gets — the reel minus the floor, which is padding outside it.
  /// `card + gap + peek` fills exactly this.
  double pagerHeight(double reelHeight) => math.max(0.0, reelHeight - floor);

  /// Resolves against the live frame.
  static FeedCardGeometry resolve(
    BuildContext context, {
    required double reelHeight,
  }) => solve(screen: MediaQuery.sizeOf(context), reelHeight: reelHeight);

  /// The pure form of [resolve] — no BuildContext, so it tests against a table of real devices.
  @visibleForTesting
  static FeedCardGeometry solve({
    required Size screen,
    required double reelHeight,
  }) {
    final width = math.max(0.0, screen.width - gutter * 2);
    var height = width * cardAspect;
    var peek = targetPeek;

    // Everything below the card fits in what is left — on a tall phone the slack becomes the floor.
    // On a short one the PEEK gives way first, and only then the card.
    // A card taller than its own viewport cannot snap -> it may never overflow.
    var floor = reelHeight - height - gap - peek;
    if (floor < 0) {
      peek = math.max(minPeek, peek + floor);
      floor = reelHeight - height - gap - peek;
      if (floor < 0) {
        height = math.max(0.0, reelHeight - gap - peek);
        floor = 0;
      }
    }

    return FeedCardGeometry(
      margin: const EdgeInsets.symmetric(horizontal: gutter),
      size: Size(width, height),
      peek: math.max(0.0, peek),
      floor: math.max(0.0, floor),
    );
  }
}
