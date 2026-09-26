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

/// The persisted half of the review prompt: one pending success and the recent request times.
class ReviewLedger {
  ReviewLedger(this._prefs, {String? launchId})
    : _launchId = launchId ?? currentLaunchId;

  static const armedLaunchKey = 'arul_review_armed_launch';
  static const armedTriggerKey = 'arul_review_armed_trigger';
  static const requestsKey = 'arul_review_requests';

  /// Play's quota may silently drop any second ask inside a month, so one per rolling [window].
  static const maxRequests = 1;
  static const window = Duration(days: 30);

  final SharedPreferences _prefs;
  final String _launchId;

  String? get _armedLaunch => _prefs.getString(armedLaunchKey);

  /// A boolean arm, not a count: many sets in one launch still buy one ask.
  Future<void> arm(ReviewTrigger trigger) async {
    // Both land in the in-memory cache before either await -> a reader never sees half an arm.
    await Future.wait([
      _prefs.setString(armedLaunchKey, _launchId),
      _prefs.setString(armedTriggerKey, trigger.key),
    ]);
  }

  bool get isArmed => _armedLaunch != null;

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
