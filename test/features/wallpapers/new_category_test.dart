// The New chip -> a WINDOW over the feed, not a category any row carries (CLAUDE.md §5b), and the one
// chip with its OWN order (owner's call, 2026-09-15): renewed, then debuts, then filler by use.
// Every rule here is an owner decision, and each one fails silently: a cap where a floor belongs
// hides half a bulk drop, a pin leaking into New puts the operator's All order on top of a chip they
// ordered by hand, and windowing on created_at would bury a batch imported long before it was published.

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
  DateTime? renewedAt,
}) => Wallpaper(
  id: id,
  title: id,
  category: category,
  kind: WallpaperKind.image,
  key: 'wallpapers/$category/$id.jpg',
  applyCount: applyCount,
  feedRank: feedRank,
  publishedAt: publishedAt,
  renewedAt: renewedAt,
);

Ringtone _rt(
  String id, {
  String title = '',
  int setCount = 0,
  int sortOrder = 0,
  int? feedRank,
  DateTime? publishedAt,
  DateTime? renewedAt,
}) => Ringtone(
  id: id,
  title: title.isEmpty ? id : title,
  category: 'murugan',
  audioKey: '$id.mp3',
  setCount: setCount,
  sortOrder: sortOrder,
  feedRank: feedRank,
  publishedAt: publishedAt,
  renewedAt: renewedAt,
);

List<String> _ids(List<Wallpaper> l) => [for (final w in l) w.id];
List<String> _newIds(List<Wallpaper> all) =>
    _ids(feedOrder(WallpaperCategory.newSlug, all, now: _now));

/// Old, quiet rows that pad a catalog past the floor without ever being new themselves.
List<Wallpaper> _padding(int n, {int applyCount = 0}) => [
  for (var i = 0; i < n; i++)
    _wp('pad$i', applyCount: applyCount, publishedAt: _daysAgo(90 + i)),
];

void main() {
  group('membership — the 7-day window', () {
    test('holds everything published inside it, with no cap', () {
      // A bulk drop is the normal case here (the Rama batch was 408 rows). 20 is a FLOOR:
      // capping New at it would hide half of a Monday import behind All for the whole week.
      final all = [
        for (var i = 0; i < 40; i++) _wp('w$i', publishedAt: _daysAgo(1)),
      ];
      expect(_newIds(all), hasLength(40));
    });

    test('is inclusive at exactly 7 days and excludes the far side', () {
      // 25 heavily-used old rows fill the floor ahead of anything that is only filler, so where `in`
      // and `out` land says which one the WINDOW took: a debut leads, filler sorts by use.
      final all = [
        ..._padding(25, applyCount: 50),
        _wp('in', publishedAt: _daysAgo(7)),
        _wp('out', publishedAt: _daysAgo(7.001)),
      ];
      final ids = _newIds(all);
      expect(ids, hasLength(kNewMinItems));
      expect(ids.first, 'in'); // a debut, ahead of every filler row
      expect(ids.last, 'out'); // filler: the newest of the rest, but the least used
    });

    test('a null published_at is never IN the window — it can only be filler', () {
      final all = [..._padding(25), _wp('legacy')];
      final ids = _newIds(all);
      expect(ids, hasLength(kNewMinItems));
      // Nulls sort last, so the 20 dated rows fill the floor first.
      expect(ids, isNot(contains('legacy')));
    });
  });

  group('tier 1 — renewed', () {
    test('a renew outranks a debut, however recent the debut', () {
      final all = [
        _wp('debut', publishedAt: _daysAgo(0.01)),
        _wp('renewed', publishedAt: _daysAgo(1), renewedAt: _daysAgo(1)),
      ];
      expect(_newIds(all), ['renewed', 'debut']);
    });

    test('renews stack — the last one renewed sits on top', () {
      final all = [
        _wp('first', renewedAt: _daysAgo(3), publishedAt: _daysAgo(3)),
        _wp('third', renewedAt: _daysAgo(1), publishedAt: _daysAgo(1)),
        _wp('second', renewedAt: _daysAgo(2), publishedAt: _daysAgo(2)),
      ];
      expect(_newIds(all), ['third', 'second', 'first']);
    });

    test('renewing an old row again moves it back to the top', () {
      final before = [
        _wp('a', renewedAt: _daysAgo(2), publishedAt: _daysAgo(2)),
        _wp('b', renewedAt: _daysAgo(1), publishedAt: _daysAgo(1)),
      ];
      expect(_newIds(before), ['b', 'a']);
      final after = [
        _wp('a', renewedAt: _daysAgo(0.1), publishedAt: _daysAgo(0.1)),
        before[1],
      ];
      expect(_newIds(after), ['a', 'b']);
    });

    test('a renewed row appears exactly once', () {
      final all = [
        _wp('both', publishedAt: _daysAgo(1), renewedAt: _daysAgo(1)),
        _wp('debut', publishedAt: _daysAgo(2)),
      ];
      expect(_newIds(all), ['both', 'debut']);
    });

    test('a renew older than the window is just a date again', () {
      final all = [
        _wp('stale', renewedAt: _daysAgo(8), publishedAt: _daysAgo(8)),
        _wp('debut', publishedAt: _daysAgo(2)),
        ..._padding(25),
      ];
      final ids = _newIds(all);
      expect(ids.first, 'debut');
      expect(ids.indexOf('stale'), greaterThan(0)); // filler now, placed by use like the rest
    });

    test('a renew still leads when the row was first published long ago', () {
      // A renew re-stamps published_at too, but tier 1 must not DEPEND on that: an older catalog,
      // or a hand edit, can carry a fresh renewed_at over an old debut.
      final all = [
        _wp('debut', publishedAt: _daysAgo(1)),
        _wp('renewed', publishedAt: _daysAgo(300), renewedAt: _daysAgo(2)),
      ];
      expect(_newIds(all), ['renewed', 'debut']);
    });
  });

  group('tier 2 — debuts', () {
    test('newest publish first, regardless of applies or pins', () {
      final all = [
        _wp('pinned-old', feedRank: 10, applyCount: 900, publishedAt: _daysAgo(5)),
        _wp('fresh', feedRank: 900, publishedAt: _daysAgo(1)),
        _wp('middle', applyCount: 40, publishedAt: _daysAgo(3)),
      ];
      expect(_newIds(all), ['fresh', 'middle', 'pinned-old']);
    });
  });

  group('ties — by applies, then id, never by pin or position', () {
    test('a batch sharing one publish instant goes most-applied first', () {
      final at = _daysAgo(1);
      final all = [
        _wp('c', applyCount: 1, publishedAt: at),
        _wp('a', applyCount: 30, publishedAt: at),
        _wp('b', applyCount: 7, publishedAt: at),
      ];
      expect(_newIds(all), ['a', 'b', 'c']);
    });

    test('with applies tied too, id decides — the pin does not', () {
      // feedRank here stands for the catalog's position, pins baked in. It must change nothing.
      final at = _daysAgo(1);
      final all = [
        _wp('zeta', feedRank: 10, publishedAt: at),
        _wp('alpha', feedRank: 990, publishedAt: at),
        _wp('mid', publishedAt: at),
      ];
      expect(_newIds(all), ['alpha', 'mid', 'zeta']);
    });

    test('renews on the same instant break the same way', () {
      final at = _daysAgo(1);
      final all = [
        _wp('low', applyCount: 1, renewedAt: at, publishedAt: at),
        _wp('high', applyCount: 9, renewedAt: at, publishedAt: at),
      ];
      expect(_newIds(all), ['high', 'low']);
    });

    test('the order does not depend on the order it was handed', () {
      final at = _daysAgo(1);
      final rows = [
        _wp('b', publishedAt: at),
        _wp('a', publishedAt: at),
        _wp('c', applyCount: 3, publishedAt: _daysAgo(2)),
      ];
      expect(_newIds(rows), _newIds(rows.reversed.toList()));
    });
  });

  group('tier 3 — the floor in a quiet week', () {
    test('a thin week is topped up to 20 with the next-newest, most-used first', () {
      final all = [
        for (var i = 0; i < 3; i++) _wp('new$i', publishedAt: _daysAgo(2 + i)),
        for (var i = 0; i < 30; i++)
          _wp('old$i', applyCount: i, publishedAt: _daysAgo(30 + i)),
      ];
      final ids = _newIds(all);
      expect(ids, hasLength(kNewMinItems));
      expect(ids.take(3), ['new0', 'new1', 'new2']);
      // Membership is RECENCY: old0..old16 are the 17 newest of the rest; old29 is not among them.
      expect(ids, containsAll([for (var i = 0; i < 17; i++) 'old$i']));
      expect(ids, isNot(contains('old29')));
      // Order is USE: old16 has the most applies of the seventeen.
      expect(ids.skip(3).first, 'old16');
      expect(ids.last, 'old0');
    });

    test('the most-applied row of all time does not buy its way into New', () {
      final all = [
        for (var i = 0; i < 20; i++) _wp('recent$i', publishedAt: _daysAgo(30 + i)),
        _wp('classic', applyCount: 9999, publishedAt: _daysAgo(500)),
      ];
      expect(_newIds(all), isNot(contains('classic')));
    });

    test('an empty window still serves the newest 20, by use', () {
      final all = [
        for (var i = 0; i < 30; i++)
          _wp('w$i', applyCount: 30 - i, publishedAt: _daysAgo(30 + i)),
      ];
      final ids = _newIds(all);
      expect(ids, hasLength(kNewMinItems));
      expect(ids, contains('w0')); // newest
      expect(ids, isNot(contains('w29'))); // oldest
      expect(ids.first, 'w0'); // and the most used of those twenty
    });

    test('no filler once renews and debuts reach the floor', () {
      final all = [
        for (var i = 0; i < 20; i++) _wp('new$i', publishedAt: _daysAgo(1)),
        _wp('classic', applyCount: 9999, publishedAt: _daysAgo(10)),
      ];
      expect(_newIds(all), isNot(contains('classic')));
    });

    test('a catalog smaller than the floor serves all of it, never pads', () {
      final all = [
        for (var i = 0; i < 5; i++) _wp('w$i', publishedAt: _daysAgo(400)),
      ];
      expect(_newIds(all), hasLength(5));
      expect(_newIds(const <Wallpaper>[]), isEmpty);
    });
  });

  group('the chip is chrome, not a category', () {
    test('the sentinel is fenced and distinct from All', () {
      expect(WallpaperCategory.newSlug, '__new__');
      expect(WallpaperCategory.newSlug, isNot(WallpaperCategory.allSlug));
    });

    test('an ordinary chip is unaffected by the window or a renew', () {
      final all = [
        _wp('a', category: 'sivan', applyCount: 5, publishedAt: _daysAgo(400)),
        _wp('b', category: 'sivan', publishedAt: _daysAgo(1), renewedAt: _daysAgo(1)),
        _wp('c', category: 'murugan', publishedAt: _daysAgo(1)),
      ];
      // Most applied first, exactly as before: a renew is New's business only.
      expect(_ids(feedOrder('sivan', all, now: _now)), ['a', 'b']);
    });

    test('All still leads with the pin, whatever New does', () {
      final all = [
        _wp('renewed', renewedAt: _daysAgo(1), publishedAt: _daysAgo(1)),
        _wp('pinned', feedRank: 10, publishedAt: _daysAgo(400)),
      ];
      expect(_ids(feedOrder(WallpaperCategory.allSlug, all, now: _now)), [
        'pinned',
        'renewed',
      ]);
      expect(_newIds(all), ['renewed', 'pinned']);
    });
  });

  group('ringtones run the identical rule', () {
    test('a renewed ringtone leads, then debuts, then filler by sets', () {
      final all = [
        _rt('debut', publishedAt: _daysAgo(2)),
        _rt('renewed', publishedAt: _daysAgo(1), renewedAt: _daysAgo(1)),
        for (var i = 0; i < 30; i++)
          _rt('old$i', setCount: i, publishedAt: _daysAgo(50 + i)),
      ];
      final feed = ringtoneFeedOrder(WallpaperCategory.newSlug, all, now: _now);
      expect(feed, hasLength(kNewMinItems));
      expect(feed.take(2).map((r) => r.id), ['renewed', 'debut']);
      expect(feed[2].id, 'old17'); // the most-set of the 18 newest old rows
    });

    test('ties go by sets then id, not by the list order sort_order and title leave', () {
      // The drained ringtone list is re-sorted by sort_order/title, so list position is authoring
      // order there. Built here in title order opposite to id order, with pins that disagree too.
      final at = _daysAgo(1);
      final all = [
        _rt('id-c', title: 'Aaa', sortOrder: 0, feedRank: 10, publishedAt: at),
        _rt('id-b', title: 'Bbb', sortOrder: 0, feedRank: 20, publishedAt: at),
        _rt('id-a', title: 'Ccc', sortOrder: 0, feedRank: 30, publishedAt: at),
      ];
      final feed = ringtoneFeedOrder(WallpaperCategory.newSlug, all, now: _now);
      expect(feed.map((r) => r.id), ['id-a', 'id-b', 'id-c']);
    });
  });
}
