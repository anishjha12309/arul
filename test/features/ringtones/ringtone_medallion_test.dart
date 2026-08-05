// The medallion's artwork is derived, not stored, so the ONLY thing keeping a
// tile from re-rolling its look is the purity of the derivation. These tests
// guard exactly that:
//
//   - same (id, category) → an identical spec, every call;
//   - the motif is a function of the CATEGORY, so two tracks of the same deity
//     carry the same emblem while the rest of the tile still differs;
//   - an unknown/empty category (the catalog's `category` is free text —
//     CLAUDE.md §5b) still resolves to a real motif instead of throwing;
//   - every derived value stays inside the ranges the handoff allows;
//   - the hash is FNV-1a and NOT String.hashCode, which Dart does not promise
//     to keep stable across runs — a golden value pins that down.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/features/ringtones/presentation/ringtone_medallion.dart';

void main() {
  RingtoneMedallionSpec spec(String id, String category) =>
      RingtoneMedallionSpec.forRingtone(id: id, category: category);

  group('RingtoneMedallionSpec determinism', () {
    test('the same id + category always yields an identical spec', () {
      for (final id in const ['r-1', 'kolaru', 'a', '', 'ரிங்டோன்-7']) {
        final a = spec(id, 'sivan');
        final b = spec(id, 'sivan');
        expect(a, b, reason: 'id "$id" must derive one spec, not two');
        expect(a.hashCode, b.hashCode);
      }
    });

    test('different ids move the artwork', () {
      final specs = {for (var i = 0; i < 40; i++) spec('ringtone-$i', 'sivan')};
      // Same category → same motif for all 40, so the only thing that can vary
      // is the hashed part. If that collapsed to one value this would be 1.
      expect(
        specs.length,
        greaterThan(10),
        reason: 'the hashed parameters must actually spread across ids',
      );
    });

    test('a golden id pins the hash: the derivation must not drift', () {
      // If this fails, the derivation changed and every shipped tile silently
      // changed costume with it. That is a decision, not an accident — update
      // the golden deliberately.
      final s = spec('dev-kolaru', 'sivan');
      expect(s.motif, RingtoneMotif.trishul);
      expect(s.groundIndex, 2);
      expect(s.dotCount, 16);
      expect(s.rotationDegrees, 340);
    });
  });

  group('RingtoneMedallionSpec motifs', () {
    test('each deity category maps to its own emblem', () {
      expect(spec('a', 'murugan').motif, RingtoneMotif.vel);
      expect(spec('a', 'sivan').motif, RingtoneMotif.trishul);
      expect(spec('a', 'amman').motif, RingtoneMotif.lotus);
      expect(spec('a', 'perumal').motif, RingtoneMotif.shankha);
      expect(spec('a', 'ayyappan').motif, RingtoneMotif.steps);
      expect(spec('a', 'temples').motif, RingtoneMotif.gopuram);
    });

    test('the category match is case-insensitive', () {
      expect(spec('a', 'Murugan').motif, RingtoneMotif.vel);
      expect(spec('a', 'TEMPLES').motif, RingtoneMotif.gopuram);
    });

    test('an unknown or empty category still resolves to a motif', () {
      // A new category is an insert, not a migration — it must never crash a
      // list that is already installed.
      for (final category in const ['', 'other', 'ganesha', 'ஐயப்பன்']) {
        expect(
          RingtoneMotif.values,
          contains(spec('a', category).motif),
          reason: 'category "$category" must not fall off the map',
        );
      }
    });

    test('two tracks of one deity share the emblem but not the tile', () {
      final a = spec('dev-kanda', 'murugan');
      final b = spec('dev-thiru', 'murugan');
      expect(a.motif, b.motif);
      expect(a, isNot(b));
    });
  });

  group('RingtoneMedallionSpec ranges', () {
    test('every derived value stays inside the handoff\'s allowed set', () {
      for (var i = 0; i < 200; i++) {
        final s = spec('id-$i', 'sivan');
        expect(s.groundIndex, inInclusiveRange(0, 9));
        expect(RingtoneMedallionSpec.dotCounts, contains(s.dotCount));
        expect(s.rotationDegrees, inInclusiveRange(0, 359));
      }
    });

    test('the dot count is not stuck on one value', () {
      // Every tile now draws the SAME skeleton — ground, dot ring, woven
      // circle, motif — and gets its identity from the parameters alone, so
      // those parameters have to actually spread. A structural coin-flip
      // (which used to decide whether the woven ring appeared at all) is
      // deliberately gone: it made rows look individually styled rather than
      // like one system.
      final counts = {
        for (var i = 0; i < 60; i++) spec('id-$i', 'sivan').dotCount,
      };
      expect(counts, containsAll(RingtoneMedallionSpec.dotCounts));
    });

    test(
      'a run of near-identical catalog ids still spreads across the grounds',
      () {
        // Real ids share long prefixes ("rt-amman-001", "rt-amman-002"). This
        // is the case the avalanche in _hash exists for: without it, four of
        // every eight tiles drew the same ground and the list read as one
        // colour.
        final grounds = {
          for (var i = 1; i <= 40; i++)
            spec(
              'rt-amman-${i.toString().padLeft(3, '0')}',
              'amman',
            ).groundIndex,
        };
        expect(
          grounds.length,
          greaterThanOrEqualTo(8),
          reason: 'a bulk import must not paint one colour',
        );
      },
    );
  });
}
