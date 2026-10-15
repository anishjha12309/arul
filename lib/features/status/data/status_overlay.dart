import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../theme/arul_tokens.dart';
import '../domain/status_photo_slot.dart';

/// What is drawn on one clip: the user's photo (in the clip's slot, or the avatar spot when the clip
/// has none) and their name in a band UNDER the clip. Null fields are simply not drawn.
@immutable
class StatusOverlaySpec {
  StatusOverlaySpec({
    this.photo,
    this.name,
    this.slot,
    required int clipHeightPx,
  }) : band = (name == null || name.isEmpty)
           ? 0
           : bandPxFor(clipHeightPx) / clipHeightPx;

  final ui.Image? photo;
  final String? name;
  final StatusPhotoSlot? slot;

  /// The name band's height as a fraction of the clip's; 0 when there is no name to show.
  final double band;

  bool get isEmpty => photo == null && band == 0;

  /// The band in the exported file: ~5.6% of the clip, in whole 32 px steps so the grown frame stays a
  /// size every hardware encoder takes (1152 -> 64, 1536 and 1824 -> 96).
  static int bandPxFor(int clipHeightPx) =>
      math.max(32, (clipHeightPx * 0.056 / 32).round() * 32);
}

/// Every size is a fraction of the clip, so the card on screen and the exported video agree to the
/// pixel whatever either one measures. The canvas is the clip with the name band under it.
@immutable
class StatusOverlayLayout {
  factory StatusOverlayLayout.of(Size canvas, StatusOverlaySpec spec) {
    final w = canvas.width;
    final clip = Rect.fromLTWH(0, 0, w, canvas.height / (1 + spec.band));
    final band = spec.band > 0
        ? Rect.fromLTRB(0, clip.bottom, w, canvas.height)
        : null;
    final photo = spec.photo == null ? null : photoSpot(clip.size, spec.slot);
    return StatusOverlayLayout._(
      clip: clip,
      band: band,
      photo: photo,
      avatar: photo != null && spec.slot == null,
      nameArea: band == null
          ? null
          : Rect.fromLTRB(w * 0.04, band.top, w * 0.96, band.bottom),
    );
  }

  /// Where the photo goes on a clip: its designed slot, else the avatar spot in the clip's bottom-right
  /// corner, the same gap from the right edge and from the band so the two never touch.
  static Rect photoSpot(Size clip, StatusPhotoSlot? slot) {
    if (slot != null) return slot.rectIn(clip);
    final w = clip.width;
    final d = w * avatarFraction;
    final inset = w * avatarInsetFraction;
    return Rect.fromLTWH(w - inset - d, clip.height - inset - d, d, d);
  }

  const StatusOverlayLayout._({
    required this.clip,
    required this.band,
    required this.photo,
    required this.avatar,
    required this.nameArea,
  });

  static const avatarFraction = 0.22;
  static const avatarInsetFraction = 0.035;

  /// The clip's own picture, at the top of the canvas.
  final Rect clip;
  final Rect? band;
  final Rect? photo;

  /// True when the clip has no slot -> the photo is a ringed avatar at the bottom-right.
  final bool avatar;
  final Rect? nameArea;
}

/// Paints [spec] on a canvas of [size] = the clip plus its name band. Nothing of ours covers the clip
/// but the photo in its slot (owner: the name sits UNDER the clip, where it hides no caption).
void paintStatusOverlay(Canvas canvas, Size size, StatusOverlaySpec spec) {
  final layout = StatusOverlayLayout.of(size, spec);
  final photo = spec.photo;
  final photoRect = layout.photo;
  if (photo != null && photoRect != null && !layout.avatar) {
    // A slot may run a few pixels past the clip's edge; the band below is never painted over.
    canvas
      ..save()
      ..clipRect(layout.clip);
    _paintPhoto(canvas, photo, photoRect, spec.slot?.shape ?? StatusSlotShape.circle);
    canvas.restore();
  }
  final band = layout.band;
  if (band != null) {
    canvas.drawRect(band, Paint()..color = ArulTokens.darkSurface);
    final line = math.max(1, size.height * 0.0022).toDouble();
    canvas.drawRect(
      Rect.fromLTWH(band.left, band.top, band.width, line),
      Paint()..color = ArulTokens.gold,
    );
    _paintName(canvas, spec.name!, layout.nameArea!, band.height);
  }
  if (photo != null && photoRect != null && layout.avatar) {
    final ring = size.width * 0.008;
    canvas.drawCircle(
      photoRect.center,
      photoRect.width / 2 + ring,
      Paint()..color = ArulTokens.gold,
    );
    _paintPhoto(canvas, photo, photoRect, StatusSlotShape.circle);
  }
}

void _paintPhoto(Canvas canvas, ui.Image photo, Rect rect, StatusSlotShape shape) {
  final src = Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble());
  // A clip, never a saveLayer + dstIn mask: Impeller dropped the mask and drew every soft shape as a
  // hard square. The soft shapes keep their outline; the feather is given up.
  canvas
    ..save()
    ..clipPath(_shapePath(shape, rect))
    ..drawImageRect(photo, src, rect, Paint()..filterQuality = FilterQuality.high)
    ..restore();
}

Path _shapePath(StatusSlotShape shape, Rect r) {
  switch (shape) {
    case StatusSlotShape.circle:
    case StatusSlotShape.softCircle:
      return Path()..addOval(r);
    case StatusSlotShape.square:
      return Path()..addRect(r);
    case StatusSlotShape.softSquare:
      return Path()
        ..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.16)));
    case StatusSlotShape.pin:
      // A teardrop pointing down: a circle in the upper part, tangents meeting at the bottom tip.
      final radius = r.width * 0.38;
      final center = Offset(r.center.dx, r.top + r.height * 0.42);
      final tip = Offset(r.center.dx, r.top + r.height * 0.98);
      final beta = math.acos(radius / (tip.dy - center.dy));
      final start = math.pi / 2 + beta;
      return Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          center.dx + radius * math.cos(start),
          center.dy + radius * math.sin(start),
        )
        ..arcTo(
          Rect.fromCircle(center: center, radius: radius),
          start,
          2 * math.pi - 2 * beta,
          false,
        )
        ..close();
  }
}

void _paintName(Canvas canvas, String name, Rect area, double bandHeight) {
  TextPainter layout(double fontSize, {double? maxWidth}) => TextPainter(
    text: TextSpan(
      text: name,
      style: TextStyle(
        color: ArulTokens.ivory,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        height: 1.15,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth ?? double.infinity);

  var fontSize = bandHeight * 0.5;
  final natural = layout(fontSize);
  if (natural.width > area.width) {
    // Long names shrink first, down to a floor that still reads on a phone; past it they ellipsise.
    fontSize = math.max(fontSize * area.width / natural.width, bandHeight * 0.34);
  }
  natural.dispose();
  final text = layout(fontSize, maxWidth: area.width);
  text.paint(
    canvas,
    Offset(
      area.left + (area.width - text.width) / 2,
      area.top + (area.height - text.height) / 2,
    ),
  );
  text.dispose();
}

/// The card's preview: the same paint the export burns in.
class StatusOverlayPainter extends CustomPainter {
  const StatusOverlayPainter(this.spec);

  final StatusOverlaySpec spec;

  @override
  void paint(Canvas canvas, Size size) => paintStatusOverlay(canvas, size, spec);

  @override
  bool shouldRepaint(StatusOverlayPainter old) =>
      !identical(old.spec.photo, spec.photo) ||
      old.spec.name != spec.name ||
      old.spec.slot != spec.slot ||
      old.spec.band != spec.band;
}

/// The overlay alone on a transparent [width]×[height] canvas — the clip plus its band — as PNG bytes
/// for the Media3 export.
Future<Uint8List> renderStatusOverlayPng(
  StatusOverlaySpec spec, {
  required int width,
  required int height,
}) async {
  final recorder = ui.PictureRecorder();
  paintStatusOverlay(
    Canvas(recorder),
    Size(width.toDouble(), height.toDouble()),
    spec,
  );
  final picture = recorder.endRecording();
  final ui.Image image;
  try {
    image = await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw StateError('status overlay toByteData failed');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}
