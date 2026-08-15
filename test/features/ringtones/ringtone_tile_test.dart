import 'package:arul/features/ringtones/presentation/ringtone_tile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RingtoneTileSpec', () {
    test('is a pure function of the id', () {
      // The whole point: a tile must not change costume when a category filter
      // re-orders the list, nor between launches, nor across an app update.
      final a = RingtoneTileSpec.forRingtone(id: 'rt-amman-01');
      final b = RingtoneTileSpec.forRingtone(id: 'rt-amman-01');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('no longer varies with category', () {
      // Category used to pick the drawn motif. It does not any more — the
      // figure comes from `deity` — so the ground must depend on the id alone.
      expect(
        RingtoneTileSpec.forRingtone(id: 'rt-1'),
        RingtoneTileSpec.forRingtone(id: 'rt-1'),
      );
    });

    test('stays inside its ranges', () {
      for (var i = 0; i < 500; i++) {
        final s = RingtoneTileSpec.forRingtone(id: 'rt-$i');
        expect(
          s.groundIndex,
          inInclusiveRange(0, RingtoneTileSpec.groundCount - 1),
        );
        expect(RingtoneTileSpec.dotCounts, contains(s.dotCount));
        expect(s.rotationDegrees, inInclusiveRange(0, 359));
      }
    });

    test('spreads grounds across ids that share a long prefix', () {
      // This is the regression the fmix32 avalanche exists for: catalog ids are
      // short and near-identical, and plain FNV-1a put most of them on the same
      // ground. With one PNG per deity the ground is now the ONLY thing telling
      // 35 Murugan rows apart, so a collapse here is far more visible than it
      // was when each tile also had its own drawn motif.
      final grounds = <int>{};
      final dots = <int>{};
      for (var i = 1; i <= 35; i++) {
        final s = RingtoneTileSpec.forRingtone(
          id: 'rt-murugan-${i.toString().padLeft(2, '0')}',
        );
        grounds.add(s.groundIndex);
        dots.add(s.dotCount);
      }
      expect(grounds.length, greaterThanOrEqualTo(8));
      expect(dots.length, RingtoneTileSpec.dotCounts.length);
    });
  });
}
