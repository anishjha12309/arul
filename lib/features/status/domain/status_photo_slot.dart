import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

/// The mask a clip's photo slot was designed around; the photo is clipped to its outline.
enum StatusSlotShape {
  circle,
  softCircle,
  pin,
  softSquare,
  square;

  static StatusSlotShape parse(Object? raw) => switch (raw) {
    'soft_circle' => softCircle,
    'pin' => pin,
    'soft_square' => softSquare,
    'square' => square,
    // An unknown or missing shape still gets a photo -> the round one every clip family accepts.
    _ => circle,
  };
}

/// Where a clip wants the user's photo: a square of side [size] × width, its top-left corner at
/// ([left] × width, [top] × height). Fractions of the CLIP, so any encode size maps the same way.
@immutable
class StatusPhotoSlot {
  const StatusPhotoSlot({
    required this.left,
    required this.top,
    required this.size,
    required this.shape,
  });

  /// Null for anything that is not a well-formed slot -> the clip falls back to the avatar spot.
  static StatusPhotoSlot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final left = raw['left'];
    final top = raw['top'];
    final size = raw['size'];
    if (left is! num || top is! num || size is! num) return null;
    if (size <= 0 || size > 1 || left < 0 || top < 0) return null;
    return StatusPhotoSlot(
      left: left.toDouble(),
      top: top.toDouble(),
      size: size.toDouble(),
      shape: StatusSlotShape.parse(raw['shape']),
    );
  }

  final double left;
  final double top;
  final double size;
  final StatusSlotShape shape;

  Rect rectIn(Size clip) => Rect.fromLTWH(
    left * clip.width,
    top * clip.height,
    size * clip.width,
    size * clip.width,
  );

  @override
  bool operator ==(Object other) =>
      other is StatusPhotoSlot &&
      other.left == left &&
      other.top == top &&
      other.size == size &&
      other.shape == shape;

  @override
  int get hashCode => Object.hash(left, top, size, shape);
}
