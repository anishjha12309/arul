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

    test('stays inside its range', () {
      for (var i = 0; i < 500; i++) {
        final s = RingtoneTileSpec.forRingtone(id: 'rt-$i');
        expect(
          s.groundIndex,
          inInclusiveRange(0, RingtoneTileSpec.groundCount - 1),
        );
      }
    });

    test('spreads grounds across ids that share a long prefix', () {
      // This is the regression the fmix32 avalanche exists for: catalog ids are
      // short and near-identical, and plain FNV-1a put most of them on the same
      // ground. Since the kolam ring was dropped the ground is the ONLY thing
      // telling 35 Murugan rows apart, so a collapse here is now fully visible
      // rather than one varying parameter among three.
      final grounds = <int>{};
      for (var i = 1; i <= 35; i++) {
        grounds.add(
          RingtoneTileSpec.forRingtone(
            id: 'rt-murugan-${i.toString().padLeft(2, '0')}',
          ).groundIndex,
        );
      }
      expect(grounds.length, greaterThanOrEqualTo(8));
    });
  });
}
