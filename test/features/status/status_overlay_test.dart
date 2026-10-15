import 'dart:ui' as ui;

import 'package:arul/features/status/data/status_overlay.dart';
import 'package:arul/features/status/domain/status_photo_slot.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _photo() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 32, 32),
    Paint()..color = const Color(0xFF00AA00),
  );
  return recorder.endRecording().toImage(32, 32);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const slot = StatusPhotoSlot(
    left: 0.3583,
    top: 0.6865,
    size: 0.2917,
    shape: StatusSlotShape.circle,
  );

  test('a slot maps width-fractions on x and size, height-fraction on y', () {
    final r = slot.rectIn(const Size(768, 1152));
    expect(r.left, closeTo(275.2, 0.1));
    expect(r.top, closeTo(790.8, 0.1));
    expect(r.width, closeTo(224.0, 0.1));
    expect(r.height, closeTo(r.width, 1e-9), reason: 'the slot is a square');
  });

  test('the same slot lands at the same relative place on screen and in the file', () {
    final screen = slot.rectIn(const Size(364, 546));
    final file = slot.rectIn(const Size(768, 1152));
    expect(screen.left / 364, closeTo(file.left / 768, 1e-9));
    expect(screen.top / 546, closeTo(file.top / 1152, 1e-9));
  });

  test('slot parsing refuses anything malformed and defaults an unknown shape', () {
    expect(StatusPhotoSlot.tryParse(null), isNull);
    expect(StatusPhotoSlot.tryParse({'left': 0.1, 'top': 0.1}), isNull);
    expect(
      StatusPhotoSlot.tryParse({'left': 0.1, 'top': 0.1, 'size': 0}),
      isNull,
    );
    expect(
      StatusPhotoSlot.tryParse({
        'left': 0.1,
        'top': 0.2,
        'size': 0.3,
        'shape': 'hexagon',
      })!.shape,
      StatusSlotShape.circle,
    );
  });

  test('the name band sits UNDER the clip, never on it; no name, no band', () async {
    final photo = await _photo();
    expect(StatusOverlaySpec.bandPxFor(1152), 64);
    expect(StatusOverlaySpec.bandPxFor(1536), 96);
    expect(StatusOverlaySpec.bandPxFor(1824), 96);
    const canvas = Size(768, 1152 + 64);
    final named = StatusOverlayLayout.of(
      canvas,
      StatusOverlaySpec(photo: photo, name: 'Anish', slot: slot, clipHeightPx: 1152),
    );
    expect(named.clip.height, closeTo(1152, 1e-6));
    expect(named.band!.top, closeTo(1152, 1e-6));
    expect(named.band!.bottom, closeTo(canvas.height, 1e-6));
    expect(named.photo!.bottom, lessThanOrEqualTo(named.band!.top + 3));
    final unnamed = StatusOverlayLayout.of(
      const Size(768, 1152),
      StatusOverlaySpec(photo: photo, slot: slot, clipHeightPx: 1152),
    );
    expect(unnamed.band, isNull);
    expect(unnamed.clip.height, 1152);
  });

  test('a clip with no slot gets the avatar inside its bottom-right corner, clear of the band', () async {
    const canvas = Size(768, 1216);
    final photo = await _photo();
    final layout = StatusOverlayLayout.of(
      canvas,
      StatusOverlaySpec(photo: photo, name: 'Anish', clipHeightPx: 1152),
    );
    expect(layout.avatar, isTrue);
    final avatar = layout.photo!;
    expect(avatar.center.dx, greaterThan(canvas.width / 2));
    // The gold ring (0.8% of the width) still leaves a gap to the right edge and to the band.
    final ring = canvas.width * 0.008;
    expect(avatar.right + ring, lessThan(canvas.width));
    expect(avatar.bottom + ring, lessThan(layout.band!.top));
    expect(layout.nameArea!.left, closeTo(canvas.width * 0.04, 1e-6));
    expect(layout.nameArea!.right, closeTo(canvas.width * 0.96, 1e-6));
    // The name toggled off does not move the photo.
    final unnamed = StatusOverlayLayout.of(
      const Size(768, 1152),
      StatusOverlaySpec(photo: photo, clipHeightPx: 1152),
    );
    expect(unnamed.photo, avatar);
  });

  test('the export PNG is exactly the clip plus its band', () async {
    final png = await renderStatusOverlayPng(
      StatusOverlaySpec(
        photo: await _photo(),
        name: 'அனிஷ் குமார்',
        slot: slot,
        clipHeightPx: 1152,
      ),
      width: 768,
      height: 1216,
    );
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    expect((frame.image.width, frame.image.height), (768, 1216));
  });

  test('every shape paints without throwing', () async {
    final photo = await _photo();
    for (final shape in StatusSlotShape.values) {
      final png = await renderStatusOverlayPng(
        StatusOverlaySpec(
          photo: photo,
          name: 'Anish',
          slot: StatusPhotoSlot(left: 0.3, top: 0.6, size: 0.4, shape: shape),
          clipHeightPx: 192,
        ),
        width: 128,
        height: 192 + 32,
      );
      expect(png, isNotEmpty, reason: shape.name);
    }
  });
}
