import 'dart:math' as math;

import 'package:flutter/widgets.dart';

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

  final double peek;

  /// Frame-coloured space left over once card, gap and peek are placed.
  final double floor;

  double get headroom => floor / 2;

  /// The half that stays below the peek — carries the odd pixel, so the reel cannot drift.
  double get underhang => floor - headroom;

  /// Side gutters — tight; the artwork carries the screen and the frame is breathing room, not a mount.
  /// **This is the WIDTH knob.** The card is height-clamped by the reel, so the gutter sets its width.
  static const gutter = 16.0;

  /// Card height ÷ width — the aspect the card ASKS for.
  /// **The one number that controls the crop's direction.** 1.78 is exactly lossless.
  /// An ordinary phone's reel cannot grant it -> read the card's own size, never this constant.
  static const cardAspect = 1.86;

  /// Vertical gap between cards. It lives on the PAGE -> the extent solved for is card + gap.
  static const gap = 16.0;

  static const radius = 24.0;

  static const scrimHeight = 180.0;

  static const actionInset = 14.0;

  /// The action row's height, and both its controls'. Pakiza's 52, so the pill and the circle sit on
  /// one baseline whatever the locale does to the label.
  ///
  /// These four live HERE, not on the private widgets that draw them, because the LOADING skeleton
  /// has to place the same objects at the same sizes and cannot import a private field. A skeleton
  /// that hand-copies them drifts out of step the first time one is tuned, and a skeleton drifting
  /// out of step with its row is the exact defect the reel's geometry rules exist to prevent
  /// ("skeleton and reel read the SAME geometry").
  static const actionBarHeight = 52.0;

  static const actionGap = 12.0;

  /// The share circle's diameter — square on [actionBarHeight] so the two controls share a baseline.
  static const shareDiameter = actionBarHeight;

  /// The Apply pill's floor width, so it reads as the dominant action even where the localized verb
  /// is one short word. The skeleton draws the FLOOR, never a midpoint: real content can then only
  /// grow into the placeholder, never shrink out of it.
  static const applyPillMinWidth = 168.0;

  /// Its ceiling, so a long Malayalam verb cannot push the share circle off the card.
  static const applyPillMaxWidth = 240.0;

  /// How much of the next card we aim to reveal — an AIM, not a promise.
  static const targetPeek = 168.0;

  /// The peek is squeezed to here before the CARD gives up any height.
  ///
  /// **This is the HEIGHT knob** — every dp off it goes straight into the card on a normal phone,
  /// where the peek is already pinned here.
  /// Never take it to zero: the sliver of the next wallpaper is why the reel reads as scrollable.
  static const minPeek = 25.0;

  /// A status clip's height ÷ width (1024×1824).
  static const clipAspect = 1824 / 1024;

  /// The extent of one page — the card plus the gap that follows it.
  /// With `padEnds: false` the pager's `viewportFraction` resolves to this.
  /// So snap, drag and fling geometry stay a stock PageView's.
  double get pageExtent => size.height + gap;

  /// The height the PAGER gets — the reel minus the floor, which is padding outside it.
  /// `card + gap + peek` fills exactly this.
  double pagerHeight(double reelHeight) => math.max(0.0, reelHeight - floor);

  /// [askAspect] replaces [cardAspect] as the shape the card asks for; the width never changes.
  static FeedCardGeometry resolve(
    BuildContext context, {
    required double reelHeight,
    double askAspect = cardAspect,
  }) => solve(
    screen: MediaQuery.sizeOf(context),
    reelHeight: reelHeight,
    askAspect: askAspect,
  );

  /// The pure form of [resolve] — no BuildContext, so it tests against a table of real devices.
  @visibleForTesting
  static FeedCardGeometry solve({
    required Size screen,
    required double reelHeight,
    double askAspect = cardAspect,
  }) {
    final width = math.max(0.0, screen.width - gutter * 2);
    var height = width * askAspect;
    var peek = targetPeek;

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
