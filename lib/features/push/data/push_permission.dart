import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics/analytics_service.dart';
import '../../../core/crash/crash_reporter.dart';

class PushPermission {
  PushPermission({
    required this._prefs,
    required this._analytics,
    required this._crash,
    this._request,
  });

  static const _kPromptedKey = 'arul_push_prompted';

  final SharedPreferences _prefs;
  final AnalyticsService _analytics;
  final CrashReporter _crash;

  /// The OS ask, as a seam. `FirebaseMessaging` is a concrete class with no interface, so injecting
  /// the object would not make this testable; injecting the one call it makes does. Null means "ask
  /// the SDK", which is what every real build does and what `flutter test` must never reach.
  final Future<AuthorizationStatus> Function()? _request;

  bool _asking = false;

  bool get alreadyPrompted => _prefs.getBool(_kPromptedKey) ?? false;

  /// Ask, if this install never has. Returns whether notifications are now permitted.
  ///
  /// Android below 13 has no runtime permission and answers `authorized` with no dialog at all — the
  /// CHANNEL is what governs visibility there. The prompt is still recorded as spent so the two
  /// paths behave identically on a later upgrade.
  Future<bool> promptOnce() async {
    if (_asking || alreadyPrompted) return false;
    _asking = true;
    try {
      final status = await (_request?.call() ?? _askSdk());
      final granted =
          status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
      await _prefs.setBool(_kPromptedKey, true);
      // GA4-only diagnostic: it answers "how many phones can a campaign even reach", which is the
      // first thing a disappointing Sent number needs ruling out. Deliberately off the PostHog list.
      _analytics.track('push_permission', properties: {'granted': granted});
      debugPrint('[Push] permission ${status.name}');
      return granted;
    } catch (error, stack) {
      // A phone with no Google Play services throws here. It must behave exactly as before, and it
      // must not be asked again every launch — the question is spent either way.
      _crash.recordError(error, stack, reason: 'push permission prompt');
      await _prefs.setBool(_kPromptedKey, true).catchError((Object _) => false);
      return false;
    } finally {
      _asking = false;
    }
  }

  static Future<AuthorizationStatus> _askSdk() async =>
      (await FirebaseMessaging.instance.requestPermission())
          .authorizationStatus;
}
