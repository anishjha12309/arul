// The New chip -> a WINDOW over the feed, not a category any row carries (CLAUDE.md §5b).
// Membership is `published_at` within kNewWindow, floored at kNewMinItems; ORDER is the ordinary
// three tiers, so New is All RESTRICTED and the two can never contradict each other.
// Every rule here is an owner decision, and each one fails silently: a cap where a floor belongs
// hides half a bulk drop, a re-sorted subset gives New a tier All does not have, and windowing on
// created_at would bury a batch that was imported long before it was published.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/ringtones/providers/ringtone_catalog_providers.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';

/// Fixed "now" -> the window is a boundary the tests have to stand on both sides of.
final _now = DateTime.utc(2026, 9, 8, 12);
DateTime _daysAgo(num d) =>
    _now.subtract(Duration(minutes: (d * 24 * 60).round()));

Wallpaper _wp(
  String id, {
  String category = 'murugan',
  int applyCount = 0,
  int? feedRank,
  DateTime? publishedAt,
}) => Wallpaper(
  id: id,
  title: id,
  category: category,
  kind: WallpaperKind.image,
  key: 'wallpapers/$category/$id.jpg',
  applyCount: applyCount,
  feedRank: feedRank,
  publishedAt: publishedAt,
);

Ringtone _rt(String id, {int setCount = 0, DateTime? publishedAt}) => Ringtone(
  id: id,
  title: id,
  category: 'murugan',
  audioKey: '$id.mp3',
  setCount: setCount,
  publishedAt: publishedAt,
);

List<String> _ids(List<Wallpaper> l) => [for (final w in l) w.id];

void main() {
  group('membership — the 7-day window', () {
    test('holds everything published inside it, with no cap', () {
      // A bulk drop is the normal case here (the Rama batch was 408 rows). 20 is a FLOOR:
      // capping New at it would hide half of a Monday import behind All for the whole week.
      final all = [
        for (var i = 0; i < 40; i++) _wp('w$i', publishedAt: _daysAgo(1)),
      ];
      expect(
        feedOrder(WallpaperCategory.newSlug, all, now: _now),
        hasLength(40),
      );
    });

    test('is inclusive at exactly 7 days and excludes the far side', () {
      final inWindow = _wp('in', publishedAt: _daysAgo(7));
      final outside = _wp('out', publishedAt: _daysAgo(7.001));
      // Held to two rows so the floor cannot mask which one the WINDOW itself took.
      expect(_ids(newSelection([inWindow], (w) => w.publishedAt, now: _now)), [
        'in',
      ]);
      expect(
        _ids(newSelection([outside], (w) => w.publishedAt, now: _now)),
        [
          'out',
        ], // present only because the floor padded it, not because it is new
      );
    });

    test(
      'a null published_at is never IN the window — it can only be padding',
      () {
        final all = [
          for (var i = 0; i < 25; i++) _wp('old$i', publishedAt: _daysAgo(60)),
          _wp('legacy'), // no published_at at all
        ];
        final window = newSelection(all, (w) => w.publishedAt, now: _now);
        expect(window, hasLength(kNewMinItems));
        // Nulls sort last, so the 20 dated rows fill the floor first.
        expect(_ids(window), isNot(contains('legacy')));
      },
    );
  });

  group('the floor — a quiet week', () {
    test(
      'a thin window is topped up to 20 with the next-newest of any age',
      () {
        final all = [
          for (var i = 0; i < 3; i++) _wp('new$i', publishedAt: _daysAgo(2)),
          for (var i = 0; i < 30; i++)
            _wp('old$i', publishedAt: _daysAgo(30 + i)),
        ];
        final window = newSelection(all, (w) => w.publishedAt, now: _now);
        expect(window, hasLength(kNewMinItems));
        expect(_ids(window), containsAll(['new0', 'new1', 'new2']));
        // Topped up by RECENCY, so the oldest rows are the ones left out.
        expect(_ids(window), contains('old0'));
        expect(_ids(window), isNot(contains('old29')));
      },
    );

    test('an empty window still serves the newest 20', () {
      final all = [
        for (var i = 0; i < 30; i++) _wp('w$i', publishedAt: _daysAgo(30 + i)),
      ];
      final window = newSelection(all, (w) => w.publishedAt, now: _now);
      expect(window, hasLength(kNewMinItems));
      expect(_ids(window), contains('w0')); // newest
      expect(_ids(window), isNot(contains('w29'))); // oldest
    });

    test('a catalog smaller than the floor serves all of it, never pads', () {
      final all = [
        for (var i = 0; i < 5; i++) _wp('w$i', publishedAt: _daysAgo(400)),
      ];
      expect(newSelection(all, (w) => w.publishedAt, now: _now), hasLength(5));
      expect(
        newSelection(<Wallpaper>[], (w) => w.publishedAt, now: _now),
        isEmpty,
      );
    });
  });

  group('order inside New', () {
    test('is pins, then applies, then catalog position', () {
      final all = [
        _wp('plain', applyCount: 5, publishedAt: _daysAgo(1)),
        _wp('popular', applyCount: 900, publishedAt: _daysAgo(2)),
        _wp('pinned', applyCount: 0, feedRank: 0, publishedAt: _daysAgo(3)),
      ];
      expect(_ids(feedOrder(WallpaperCategory.newSlug, all, now: _now)), [
        'pinned',
        'popular',
        'plain',
      ]);
    });

    test('never contradicts All — New is All restricted to the window', () {
      // The invariant behind returning the subset in CATALOG order rather than recency order:
      // re-sorting it first would hand orderedByUse a different last tier from the one All gets.
      final all = [
        for (var i = 0; i < 24; i++)
          _wp(
            'w$i',
            // Tied on both real tiers -> only the last tier can separate them.
            applyCount: 7,
            publishedAt: _daysAgo(i.isEven ? 1 + i : 40 + i),
          ),
      ];
      final inNew = _ids(feedOrder(WallpaperCategory.newSlug, all, now: _now));
      final inAll = _ids(feedOrder(WallpaperCategory.allSlug, all, now: _now));
      expect(inNew, isNotEmpty);
      expect(inAll.where(inNew.contains).toList(), inNew);
    });
  });

  group('the chip is chrome, not a category', () {
    test('the sentinel is fenced and distinct from All', () {
      expect(WallpaperCategory.newSlug, '__new__');
      expect(WallpaperCategory.newSlug, isNot(WallpaperCategory.allSlug));
    });

    test('an ordinary chip is unaffected by the window', () {
      final all = [
        _wp('a', category: 'sivan', publishedAt: _daysAgo(400)),
        _wp('b', category: 'murugan', publishedAt: _daysAgo(1)),
      ];
      expect(_ids(feedOrder('sivan', all, now: _now)), ['a']);
    });
  });

  group('ringtones run the identical rule', () {
    test('window, floor and order all come from the shared helper', () {
      final all = [
        for (var i = 0; i < 3; i++)
          _rt('new$i', setCount: i, publishedAt: _daysAgo(2)),
        for (var i = 0; i < 30; i++)
          _rt('old$i', publishedAt: _daysAgo(50 + i)),
      ];
      final feed = ringtoneFeedOrder(WallpaperCategory.newSlug, all, now: _now);
      expect(feed, hasLength(kNewMinItems));
      // Most-SET first, exactly as the All chip orders this tab.
      expect(feed.first.id, 'new2');
    });
  });
}
