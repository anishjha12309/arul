import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// What armed the ask — rides on `review_prompt_requested` as `trigger`.
enum ReviewTrigger {
  wallpaperStatic('wallpaper_static'),
  wallpaperLive('wallpaper_live'),
  ringtone('ringtone');

  const ReviewTrigger(this.key);

  final String key;

  static ReviewTrigger? fromKey(String? key) {
    for (final t in values) {
      if (t.key == key) return t;
    }
    return null;
  }
}

/// One id per process. An arm stamped with THIS id belongs to the launch that earned it, and the
/// ask waits for a later cold open — a resume never builds a new process, so it never qualifies.
final String currentLaunchId =
    '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

/// The persisted half of the review prompt: one pending success, the success history that decides
/// whether someone has used the app enough to rate it, and the recent request times.
class ReviewLedger {
  ReviewLedger(this._prefs, {String? launchId, DateTime Function()? clock})
    : _launchId = launchId ?? currentLaunchId,
      _clock = clock ?? DateTime.now;

  static const armedLaunchKey = 'arul_review_armed_launch';
  static const armedTriggerKey = 'arul_review_armed_trigger';
  static const requestsKey = 'arul_review_requests';
  static const successesKey = 'arul_review_successes';
  static const firstSuccessKey = 'arul_review_first_success';

  /// One ask per rolling [window] — Apple's three-a-year ceiling, which Play's unpublished quota
  /// sits under; a second ask sooner is dropped silently yet still spends the arm.
  static const maxRequests = 1;
  static const window = Duration(days: 120);

  /// Rating-prompt libraries default to 7–10 days and 10 launches; most installs here are gone
  /// within days, so this asks those who came back after a few real uses.
  static const minSuccesses = 2;
  static const minEngagement = Duration(days: 3);

  final SharedPreferences _prefs;
  final String _launchId;
  final DateTime Function() _clock;

  String? get _armedLaunch => _prefs.getString(armedLaunchKey);

  /// A boolean arm, not a count: many sets in one launch still buy one ask. Every success also
  /// counts toward [engaged].
  Future<void> arm(ReviewTrigger trigger) async {
    final successes = (_prefs.getInt(successesKey) ?? 0) + 1;
    final first = _prefs.getInt(firstSuccessKey);
    // All land in the in-memory cache before any await -> a reader never sees half an arm.
    await Future.wait([
      _prefs.setString(armedLaunchKey, _launchId),
      _prefs.setString(armedTriggerKey, trigger.key),
      _prefs.setInt(successesKey, successes),
      if (first == null)
        _prefs.setInt(firstSuccessKey, _clock().millisecondsSinceEpoch),
    ]);
  }

  bool get isArmed => _armedLaunch != null;

  int get successes => _prefs.getInt(successesKey) ?? 0;

  /// Enough successes, and the first one at least [minEngagement] ago — they came back.
  bool engaged(DateTime now) {
    final first = _prefs.getInt(firstSuccessKey);
    if (first == null || successes < minSuccesses) return false;
    return now.difference(DateTime.fromMillisecondsSinceEpoch(first)) >=
        minEngagement;
  }

  bool get armedBeforeThisLaunch {
    final armed = _armedLaunch;
    return armed != null && armed != _launchId;
  }

  ReviewTrigger? get armedTrigger =>
      ReviewTrigger.fromKey(_prefs.getString(armedTriggerKey));

  List<DateTime> _requests() {
    final raw = _prefs.getStringList(requestsKey) ?? const <String>[];
    return [
      for (final s in raw)
        if (int.tryParse(s) case final ms?)
          DateTime.fromMillisecondsSinceEpoch(ms),
    ];
  }

  /// A clock set backwards makes a future stamp; it still counts, so the cap can only get stricter.
  int requestsWithin(DateTime now) =>
      _requests().where((t) => now.difference(t) < window).length;

  bool capReached(DateTime now) => requestsWithin(now) >= maxRequests;

  /// Consumes the pending success and stamps the ask. Returns what [restore] needs to undo it.
  Future<({String? launch, String? trigger})> consume(DateTime now) async {
    final undo = (
      launch: _armedLaunch,
      trigger: _prefs.getString(armedTriggerKey),
    );
    final kept = [
      for (final t in _requests())
        if (now.difference(t) < window) t.millisecondsSinceEpoch.toString(),
      now.millisecondsSinceEpoch.toString(),
    ];
    await _prefs.setStringList(requestsKey, kept);
    await _prefs.remove(armedLaunchKey);
    await _prefs.remove(armedTriggerKey);
    return undo;
  }

  /// Puts back an arm [consume] took and drops its stamp — Play refused, so nothing was asked.
  Future<void> restore(
    ({String? launch, String? trigger}) undo,
    DateTime stamp,
  ) async {
    final ms = stamp.millisecondsSinceEpoch.toString();
    final raw = [...?_prefs.getStringList(requestsKey)]..remove(ms);
    await _prefs.setStringList(requestsKey, raw);
    final launch = undo.launch;
    final trigger = undo.trigger;
    if (launch != null) await _prefs.setString(armedLaunchKey, launch);
    if (trigger != null) await _prefs.setString(armedTriggerKey, trigger);
  }
}
