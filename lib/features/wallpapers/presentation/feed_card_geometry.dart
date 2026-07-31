import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The resting size of one reel card, the peek below it, and the floor below
/// that.
///
/// **A tall card on tight gutters, filling the reel** (owner's call, chosen from
/// rendered mockups, 2026-07-30): 20dp gutters and a 1:1.86 card, which on a
/// 1080×2400 phone is **353×656** with a 56dp peek and no floor at all.
///
/// The whole reel height is spoken for — `card + gap + peek + floor` — so the
/// card can only grow if one of the other three gives way. At this shape it
/// consumes everything: the floor is zero and the peek is squeezed well below
/// [targetPeek], which is exactly what the clamps in [solve] exist to do.
///
/// ## The crop, stated plainly
///
/// The catalog is 9:16 (1024×1824, ratio 1:1.78). At 1:1.86 the card is very
/// slightly TALLER than the artwork, so `BoxFit.cover` matches the height and
/// overflows the width: about **4.4% is trimmed off the left and right edges**,
/// and nothing at all off the top or bottom. That is the cheap direction — the
/// margins of a devotional composition, never the crown or the feet.
///
/// It is worth knowing this flipped. Earlier shapes were *squarer* than 9:16 and
/// cropped vertically, which is why [ViewerMedia.cropAlignment] carries an
/// upward bias; at this aspect that bias is dormant (there is no vertical
/// overflow to bias) and only its centred horizontal component applies. Keep it
/// — it is correct in both directions, and it comes back the moment [cardAspect]
/// drops below 1.78.
///
/// ## History — four shapes already rejected, do not revisit
///
///  * **Full-bleed width** (1:1.71, 16dp gutters) — read as edge-to-edge, no air.
///  * **Locked to the DEVICE aspect** (1:2.22) — a sliver that cropped ~20% off
///    the sides and crowded the Apply/Share row.
///  * **Pakiza's card verbatim** (1:1.63, 18dp gutters) — too tall, too tight.
///  * **Short and wide** (1:1.40, 32dp gutters) — cost 21% off the top and
///    bottom, which is the expensive direction for devotional art.
///
/// Extracted from `feed_screen.dart` so it can be unit-tested directly: it has
/// been rewritten several times, and measuring a card through a full feed render
/// is a slow and indirect way to catch a number being wrong.
@immutable
class FeedCardGeometry {
  const FeedCardGeometry({
    required this.margin,
    required this.size,
    required this.peek,
    required this.floor,
  });

  /// Card margin. Horizontal only — the card sits flush with the top of the
  /// reel, and the gap below it belongs to the page (see [pageExtent]).
  final EdgeInsets margin;

  final Size size;

  /// How much of the NEXT card shows below this one.
  final double peek;

  /// Frame-coloured space below the peek. The reel's visible bottom edge, and
  /// the reason the card reads as placed rather than jammed against the screen.
  final double floor;

  // ─── The knobs ──────────────────────────────────────────────────────────────

  /// Side gutters. Tight — the artwork carries the screen, and the frame is a
  /// hairline of breathing room rather than a mount.
  static const gutter = 20.0;

  /// Card height ÷ width. **The one number that controls the crop** — see the
  /// class doc. 1.78 is exactly lossless; 1.86 trims ~4.4% off the sides.
  ///
  /// Below 1.78 the crop flips to top/bottom and gets expensive fast, so treat
  /// that as a boundary rather than a slider.
  static const cardAspect = 1.86;

  /// Vertical gap between consecutive cards. It lives on the PAGE, so the page
  /// extent the viewport fraction solves for is card + gap.
  static const gap = 14.0;

  /// Card corner radius.
  static const radius = 26.0;

  /// Bottom scrim height, and the band the action row lives in.
  static const scrimHeight = 180.0;

  /// Inset of the Apply/Share row from the card's left, right and bottom edges.
  static const actionInset = 14.0;

  /// How much of the next card we aim to reveal.
  ///
  /// An AIM, not a promise. At the current [cardAspect] the card takes nearly
  /// the whole reel, so on a normal phone this clamps down to ~56 and the floor
  /// is zero. The generous value still earns its keep on an unusually tall
  /// screen, where it is reachable and keeps the reel from ending in dead space.
  static const targetPeek = 168.0;

  /// The peek will be squeezed to here before the CARD gives up any height — a
  /// reel with no peek at all loses its only static cue that it scrolls.
  static const minPeek = 44.0;

  /// The extent of one page: the card plus the gap that follows it. With
  /// `padEnds: false` this is what the pager's `viewportFraction` resolves to,
  /// so snap, drag and fling geometry stay a stock PageView's.
  double get pageExtent => size.height + gap;

  /// The height the PAGER gets — the reel minus the floor, which is padding
  /// outside it. `card + gap + peek` fills exactly this.
  double pagerHeight(double reelHeight) => math.max(0.0, reelHeight - floor);

  /// Resolves against the live frame.
  static FeedCardGeometry resolve(
    BuildContext context, {
    required double reelHeight,
  }) => solve(screen: MediaQuery.sizeOf(context), reelHeight: reelHeight);

  /// The pure form of [resolve] — no BuildContext, so it can be tested against a
  /// table of real devices.
  @visibleForTesting
  static FeedCardGeometry solve({
    required Size screen,
    required double reelHeight,
  }) {
    final width = math.max(0.0, screen.width - gutter * 2);
    var height = width * cardAspect;
    var peek = targetPeek;

    // Everything below the card has to fit in what is left. On a tall phone
    // there is slack and it becomes the floor; on a short one the peek gives way
    // first, and only then the card — a card taller than its own viewport cannot
    // snap, so it can never be allowed to overflow.
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
