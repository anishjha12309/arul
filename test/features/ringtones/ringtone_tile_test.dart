import 'package:arul/features/ringtones/presentation/ringtone_tile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RingtoneTileSpec', () {
    test('is a pure function of the id', () {
      // A tile must not change costume when a filter re-orders the list, between launches, or across an app update.
      final a = RingtoneTileSpec.forRingtone(id: 'rt-amman-01');
      final b = RingtoneTileSpec.forRingtone(id: 'rt-amman-01');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('no longer varies with category', () {
      // Category no longer picks the drawn motif -> the figure comes from `deity` -> the ground depends on the id alone.
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
      // Catalog ids are short and near-identical -> plain FNV-1a put most on one ground -> hence the fmix32 avalanche.
      // The kolam ring is gone -> the ground is the ONLY thing telling Murugan rows apart -> a collapse is fully visible.
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
