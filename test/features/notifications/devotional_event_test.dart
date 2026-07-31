import 'package:flutter_test/flutter_test.dart';

import 'package:arul/features/notifications/domain/devotional_event.dart';

/// The festival table is hand-authored data, not computation, so these guard the
/// two things that can silently break it: a date that falls out of order (which
/// makes `nextOccurrenceAfter` return the wrong one) and coverage quietly
/// running out.
///
/// They do NOT — and cannot — check that the dates are astronomically right.
/// Only a panchangam can, and that verification is a release-checklist item; see
/// the banner on [festivalEvents] and docs/notifications.md.
void main() {
  group('festival table integrity', () {
    test('every key is unique and stable-looking', () {
      final keys = festivalEvents.map((e) => e.key).toList();
      expect(keys.toSet(), hasLength(keys.length), reason: 'duplicate key');
      for (final key in keys) {
        expect(
          key,
          matches(RegExp(r'^[a-z][a-z0-9_]*$')),
          reason: 'keys feed notification ids and must never be re-styled',
        );
      }
    });

    test('every festival has copy that can fire days EARLY', () {
      for (final e in festivalEvents) {
        expect(e.title, isNotEmpty, reason: e.key);
        expect(e.body, isNotEmpty, reason: e.key);
        expect(e.emoji, isNotEmpty, reason: e.key);
        // The reminder fires kFestivalLeadDays ahead, so copy that names a
        // weekday or says "today" would simply be wrong when it arrives.
        expect(
          e.body.toLowerCase(),
          isNot(contains('today')),
          reason: '${e.key} fires $kFestivalLeadDays days early',
        );
      }
    });

    test('dates are strictly ascending within each festival', () {
      for (final e in festivalEvents) {
        for (var i = 1; i < e.dates.length; i++) {
          expect(
            e.dates[i].isAfter(e.dates[i - 1]),
            isTrue,
            reason:
                '${e.key}: ${e.dates[i]} does not follow ${e.dates[i - 1]} — '
                'nextOccurrenceAfter walks this list in order',
          );
        }
      }
    });

    test('the table still covers a useful horizon', () {
      // Authored to the end of 2031. This trips a year before it runs dry, so
      // the refresh is a chore and not an outage.
      final deadline = DateTime(2030, 1, 1);
      for (final e in festivalEvents) {
        final end = e.coverageEnd;
        expect(end, isNotNull, reason: '${e.key} has no dates at all');
        expect(
          end!.isAfter(deadline),
          isTrue,
          reason:
              '${e.key} runs out at $end — extend the table '
              '(docs/notifications.md) before it stops notifying',
        );
      }
    });

    test('every category is one the catalog actually browses', () {
      // The payload is a category slug and the tap handler selects it; a typo
      // would land the user on an empty feed. CLAUDE.md §5b.
      const slugs = {
        'all',
        'amman',
        'ayyappan',
        'murugan',
        'perumal',
        'sivan',
        'temples',
      };
      for (final e in festivalEvents) {
        expect(slugs, contains(e.category), reason: e.key);
      }
      for (final d in weeklyDevotionalDays) {
        expect(slugs, contains(d.category), reason: d.key);
      }
    });

    test('all six deities are represented across the year', () {
      // A reminder set that never mentions Ayyappan or Perumal is a reminder
      // set that only serves part of the catalog.
      final covered = festivalEvents.map((e) => e.category).toSet();
      for (final slug in ['amman', 'ayyappan', 'murugan', 'perumal', 'sivan']) {
        expect(covered, contains(slug), reason: 'no festival for $slug');
      }
    });
  });

  group('nextOccurrenceAfter', () {
    final event = festivalEvents.firstWhere((e) => e.key == 'thai_pongal');

    test('returns the first date STRICTLY after the given day', () {
      final first = event.dates.first;
      // Asking on the day itself must move on: a festival whose reminder window
      // has closed should not be re-armed for the same occurrence.
      expect(event.nextOccurrenceAfter(first), event.dates[1]);
      expect(
        event.nextOccurrenceAfter(first.subtract(const Duration(days: 1))),
        first,
      );
    });

    test('ignores the time of day on the query', () {
      final first = event.dates.first;
      final lateOnPreviousDay = first.subtract(
        const Duration(hours: 1),
      ); // 23:00 the day before
      expect(event.nextOccurrenceAfter(lateOnPreviousDay), first);
    });

    test('returns null once the table is exhausted — it never guesses', () {
      // The whole safety property: a lunisolar festival cannot be extrapolated
      // by adding a year, so running out must mean "stop notifying", never
      // "notify on a made-up day".
      expect(event.nextOccurrenceAfter(DateTime(2099, 1, 1)), isNull);
    });
  });

  group('weekly reminders', () {
    test('are real weekdays with copy', () {
      expect(weeklyDevotionalDays, isNotEmpty);
      for (final d in weeklyDevotionalDays) {
        expect(d.weekday, inInclusiveRange(DateTime.monday, DateTime.sunday));
        expect(d.title, isNotEmpty);
        expect(d.body, isNotEmpty);
      }
    });

    test('keys are unique and do not collide with festival keys', () {
      final weekly = weeklyDevotionalDays.map((d) => d.key).toSet();
      expect(weekly, hasLength(weeklyDevotionalDays.length));
      expect(
        weekly.intersection(festivalEvents.map((e) => e.key).toSet()),
        isEmpty,
      );
    });
  });
}
