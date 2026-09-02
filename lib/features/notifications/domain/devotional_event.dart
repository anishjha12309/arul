/// The devotional calendar Arul notifies on — a weekly rhythm that repeats, and a table that does not.
///
/// Hindu festivals are LUNISOLAR: their dates ride the tithi or nakshatra at sunrise at a place.
/// That is astronomy, and no Dart package computes it to a standard worth showing a devotee.
/// A festival wrong by a week is worse than saying nothing -> the dates are DATA, never computed.
///
///  * **It fails silent, never wrong** — [FestivalEvent.nextOccurrenceAfter] returns null once the
///    table runs out, and the scheduler skips that festival;
///  * **It has to be refreshed** — the table runs to the end of 2031 (docs/notifications.md).
///
/// Reminders fire [kFestivalLeadDays] days AHEAD and never name a date.
/// So the ±1-day disagreement between panchangams is invisible to the user.
library;

/// How many days before a festival its reminder fires.
///
/// Far enough ahead that the copy can honestly say "is near" and an almanac's day never shows.
/// Close enough that the user still has time to change their wallpaper for it.
const int kFestivalLeadDays = 3;

/// A weekday that carries devotional weight, surfaced as a recurring reminder.
///
/// Unlike the festivals it needs NO table — the OS repeats it natively via `dayOfWeekAndTime`.
class WeeklyDevotionalDay {
  const WeeklyDevotionalDay({
    required this.key,
    required this.weekday,
    required this.category,
    required this.emoji,
    required this.title,
    required this.body,
  });

  /// Stable identifier feeding the notification id — **never change it once shipped**.
  /// A changed key orphans the old scheduled notification instead of replacing it.
  final String key;

  /// `DateTime.monday` … `DateTime.sunday`.
  final int weekday;

  /// The catalog category this day belongs to -> a tap opens the feed already filtered to it.
  /// Must match a slug in the catalog (CLAUDE.md §5b).
  final String category;

  final String emoji;
  final String title;
  final String body;
}

/// The weekly reminders.
///
/// Deliberately ONE, on Friday — velli kizhamai is the most widely observed day in Tamil practice.
/// One a week keeps volume comparable to Pakiza's, instead of Arul becoming the noisier of the pair.
/// Adding Monday, Tuesday or Saturday is a one-entry change — ids, channels and scheduling derive.
/// Weigh it against the volume note above before doing so.
const weeklyDevotionalDays = <WeeklyDevotionalDay>[
  WeeklyDevotionalDay(
    key: 'velli_kizhamai',
    weekday: DateTime.friday,
    category: 'amman',
    emoji: '🪔',
    title: 'Velli Kizhamai',
    body:
        "It's Friday — Amman's day. Light a lamp, take a quiet moment, and "
        'dress your screen for it.',
  ),
];

/// One festival in the table — stable identity, copy, and the explicit Gregorian dates it falls on.
class FestivalEvent {
  const FestivalEvent({
    required this.key,
    required this.category,
    required this.emoji,
    required this.title,
    required this.body,
    required this.dates,
  });

  /// Stable identifier — feeds the notification id. Never change once shipped.
  final String key;

  /// Catalog category to open when the reminder is tapped (CLAUDE.md §5b).
  /// `WallpaperCategory.allSlug` for a festival that isn't one deity's.
  final String category;

  final String emoji;

  /// Headline, shown after [emoji].
  final String title;

  /// Body copy. It fires [kFestivalLeadDays] days EARLY -> speak in the near future, never name a date.
  final String body;

  /// The Gregorian dates this festival falls on, ascending — verified against a panchangam.
  final List<DateTime> dates;

  /// The first date strictly after [from], or null when the table has run out for this festival.
  ///
  /// Null is the SAFE answer -> the caller must treat it as "do not schedule".
  /// Adding 365 days to guess would put a lunisolar festival up to a fortnight wrong.
  DateTime? nextOccurrenceAfter(DateTime from) {
    final floor = DateTime(from.year, from.month, from.day);
    for (final date in dates) {
      if (date.isAfter(floor)) return date;
    }
    return null;
  }

  /// The latest date in the table for this festival — how far its coverage runs.
  DateTime? get coverageEnd => dates.isEmpty ? null : dates.last;
}

/// Dates are DATA, verified by hand against a published Tamil panchangam — never computed.
///
/// One date per line with the weekday in a comment, precisely so it can be eyeballed.
/// When EXTENDING coverage (the test starts failing from 2030), verify the new rows the same way.
/// The solar entries (Pongal, Makaravilakku, Puthandu, Aadi Perukku) follow fixed Tamil rules.
/// Everything tithi- or nakshatra-based must be checked against a panchangam.
/// Residual error is contained by design: reminders fire early and never name a date.
/// A festival with no future date is skipped outright rather than guessed at.
/// Ordered by the Tamil year (Chithirai → Panguni); all six catalog categories are represented.
final festivalEvents = <FestivalEvent>[
  FestivalEvent(
    key: 'puthandu',
    category: 'temples',
    emoji: '🌸',
    title: 'Tamil New Year',
    body:
        'Puthandu is near — a new year, a fresh start. Begin it with a new '
        'wallpaper on your screen.',
    // Solar: the sun's entry into Mesha. Apr 14 in all these years.
    dates: [
      DateTime(2027, 4, 14), // Wed
      DateTime(2028, 4, 14), // Fri
      DateTime(2029, 4, 14), // Sat
      DateTime(2030, 4, 14), // Sun
      DateTime(2031, 4, 14), // Mon
    ],
  ),
  FestivalEvent(
    key: 'vaikasi_visakam',
    category: 'murugan',
    emoji: '🦚',
    title: 'Vaikasi Visakam',
    body:
        'Vaikasi Visakam approaches — the day Murugan came into the world. '
        'Set his form on your screen for it.',
    dates: [
      DateTime(2027, 5, 31),
      DateTime(2028, 6, 6),
      DateTime(2029, 5, 27),
      DateTime(2030, 6, 15),
      DateTime(2031, 6, 4),
    ],
  ),
  FestivalEvent(
    key: 'aadi_perukku',
    category: 'amman',
    emoji: '🌊',
    title: 'Aadi Perukku',
    body:
        'Aadi Perukku is near — the rivers rise and the year turns green '
        'again. Mark it with an Amman wallpaper.',
    // Solar: the 18th day of Aadi.
    dates: [
      DateTime(2026, 8, 3), // Mon
      DateTime(2027, 8, 3), // Tue
      DateTime(2028, 8, 2), // Wed
      DateTime(2029, 8, 3), // Fri
      DateTime(2030, 8, 3), // Sat
      DateTime(2031, 8, 3), // Sun
    ],
  ),
  FestivalEvent(
    key: 'varalakshmi_vratham',
    category: 'amman',
    emoji: '🪷',
    title: 'Varalakshmi Vratham',
    body:
        'Varalakshmi Vratham is near — the day the Goddess grants boons. '
        'Welcome her with a wallpaper worthy of it.',
    dates: [
      DateTime(2026, 8, 28),
      DateTime(2027, 8, 13),
      DateTime(2028, 8, 4),
      DateTime(2029, 8, 24),
      DateTime(2030, 8, 9),
      DateTime(2031, 7, 30),
    ],
  ),
  FestivalEvent(
    key: 'krishna_jayanthi',
    category: 'perumal',
    emoji: '🪈',
    title: 'Krishna Jayanthi',
    body:
        'Gokulashtami approaches — the night Krishna was born. Ready a '
        'wallpaper to celebrate him with.',
    dates: [
      DateTime(2026, 9, 4),
      DateTime(2027, 8, 25),
      DateTime(2028, 9, 11),
      DateTime(2029, 9, 1),
      DateTime(2030, 8, 21),
      DateTime(2031, 9, 9),
    ],
  ),
  FestivalEvent(
    key: 'vinayaka_chaturthi',
    category: 'temples',
    emoji: '🐘',
    title: 'Vinayaka Chaturthi',
    body:
        'Vinayaka Chaturthi is near — the remover of obstacles arrives. '
        'Begin the festival with a fresh screen.',
    dates: [
      DateTime(2026, 9, 14),
      DateTime(2027, 9, 4),
      DateTime(2028, 8, 23),
      DateTime(2029, 9, 11),
      DateTime(2030, 9, 1),
      DateTime(2031, 8, 21),
    ],
  ),
  FestivalEvent(
    key: 'navaratri',
    category: 'amman',
    // NOT the dancing figure — it reads as nightclub shorthand, flippant on a post about the Goddess.
    // The rosette carries the festive register without depicting anyone.
    emoji: '🏵️',
    title: 'Navaratri',
    body:
        'Nine nights of the Goddess are almost here. Dress your screen for '
        'Navaratri and change it as the days turn.',
    dates: [
      DateTime(2026, 10, 11),
      DateTime(2027, 9, 30),
      DateTime(2028, 9, 19),
      DateTime(2029, 10, 8),
      DateTime(2030, 9, 27),
      DateTime(2031, 10, 17),
    ],
  ),
  FestivalEvent(
    key: 'deepavali',
    category: 'temples',
    emoji: '🪔',
    title: 'Deepavali',
    body:
        'Deepavali is near — light over darkness, and the year at its '
        'brightest. Get a wallpaper ready to share.',
    dates: [
      DateTime(2026, 11, 8),
      DateTime(2027, 10, 29),
      DateTime(2028, 10, 17),
      DateTime(2029, 11, 5),
      DateTime(2030, 10, 26),
      DateTime(2031, 11, 14),
    ],
  ),
  FestivalEvent(
    key: 'karthigai_deepam',
    category: 'sivan',
    emoji: '🔥',
    title: 'Karthigai Deepam',
    body:
        'Karthigai Deepam approaches — the hill lamp and a row of flames at '
        'every door. Let your screen carry one too.',
    dates: [
      DateTime(2026, 11, 23),
      DateTime(2027, 12, 12),
      DateTime(2028, 11, 30),
      DateTime(2029, 12, 19),
      DateTime(2030, 12, 9),
      DateTime(2031, 11, 28),
    ],
  ),
  FestivalEvent(
    key: 'mandala_pooja',
    category: 'ayyappan',
    emoji: '🌿',
    title: 'Mandala Pooja',
    body:
        'Mandala Pooja is near — forty-one days of vratham come to their '
        'close at Sabarimala. Swamiye Saranam Ayyappa.',
    // 41 days from Vrischikam 1 — very nearly fixed in the Gregorian year.
    dates: [
      DateTime(2026, 12, 27), // Sun
      DateTime(2027, 12, 27), // Mon
      DateTime(2028, 12, 26), // Tue
      DateTime(2029, 12, 26), // Wed
      DateTime(2030, 12, 27), // Fri
      DateTime(2031, 12, 27), // Sat
    ],
  ),
  FestivalEvent(
    key: 'vaikunta_ekadasi',
    category: 'perumal',
    emoji: '🛕',
    title: 'Vaikunta Ekadasi',
    body:
        'Vaikunta Ekadasi approaches — the day the gate of heaven opens. '
        'Mark it with Perumal on your screen.',
    dates: [
      DateTime(2026, 12, 30),
      DateTime(2027, 12, 19),
      DateTime(2029, 1, 6),
      DateTime(2029, 12, 27),
      DateTime(2030, 12, 16),
      DateTime(2032, 1, 3),
    ],
  ),
  FestivalEvent(
    key: 'thai_pongal',
    category: 'temples',
    emoji: '🍚',
    title: 'Thai Pongal',
    body:
        'Pongal is near — the harvest, the sun, and a whole month of good '
        'things. Start it with a fresh wallpaper.',
    // Solar: the sun's entry into Makara.
    dates: [
      DateTime(2027, 1, 15), // Fri
      DateTime(2028, 1, 15), // Sat
      DateTime(2029, 1, 14), // Sun
      DateTime(2030, 1, 14), // Mon
      DateTime(2031, 1, 15), // Wed
    ],
  ),
  FestivalEvent(
    key: 'makaravilakku',
    category: 'ayyappan',
    emoji: '⭐',
    title: 'Makaravilakku',
    body:
        'Makaravilakku is almost here — the star over Sabarimala and the end '
        'of the season. Swamiye Saranam Ayyappa.',
    // Falls with Makara Sankranti, i.e. the same day as Pongal.
    dates: [
      DateTime(2027, 1, 15),
      DateTime(2028, 1, 15),
      DateTime(2029, 1, 14),
      DateTime(2030, 1, 14),
      DateTime(2031, 1, 15),
    ],
  ),
  FestivalEvent(
    key: 'thai_pusam',
    category: 'murugan',
    emoji: '🦚',
    title: 'Thai Pusam',
    body:
        'Thai Pusam approaches — kavadi, the vel, and the long walk to '
        'Murugan. Carry him on your screen for it.',
    dates: [
      DateTime(2027, 1, 23),
      DateTime(2028, 2, 11),
      DateTime(2029, 1, 30),
      DateTime(2030, 1, 19),
      DateTime(2031, 2, 7),
    ],
  ),
  FestivalEvent(
    key: 'maha_sivarathiri',
    category: 'sivan',
    emoji: '🔱',
    title: 'Maha Sivarathiri',
    body:
        'Maha Sivarathiri is near — the great night of Siva, kept awake in '
        'prayer. Set his form on your screen.',
    dates: [
      DateTime(2027, 3, 6),
      DateTime(2028, 2, 23),
      DateTime(2029, 2, 11),
      DateTime(2030, 3, 2),
      DateTime(2031, 2, 20),
    ],
  ),
  FestivalEvent(
    key: 'panguni_uthiram',
    category: 'murugan',
    emoji: '🌺',
    title: 'Panguni Uthiram',
    body:
        'Panguni Uthiram approaches — the day of divine weddings, and of '
        'Murugan and Deivanai. Mark it with a new wallpaper.',
    dates: [
      DateTime(2027, 4, 1),
      DateTime(2028, 3, 20),
      DateTime(2029, 4, 8),
      DateTime(2030, 3, 28),
      DateTime(2031, 4, 16),
    ],
  ),
];
