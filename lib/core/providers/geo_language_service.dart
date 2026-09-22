import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/providers/auth_providers.dart';
import '../api/api_client.dart';
import 'locale_provider.dart';
import 'shared_preferences_provider.dart';

part 'geo_language_service.g.dart';

/// Hands a `GET /geo` answer to its one consumer, [LocaleNotifier.setGeoHint].
typedef GeoAnswerHandler =
    Future<void> Function({String? lang, String? region});

/// A FRESH install's region hint, asked ONCE -> the Worker answers from Cloudflare's `request.cf`.
///
/// Fired from the splash beside `warmUp()`, never awaited -> the splash routes on the auth seed alone.
/// Offline, timed out or not live yet -> nothing stored, pending kept -> the next cold start asks again.
/// At most ONE request per process whatever happens -> no retry loop can ever come from here.
class GeoLanguageService {
  GeoLanguageService({
    required this._api,
    required this._prefs,
    required this._onAnswer,
    // 12 s, not 5. The answer is ~200 bytes and decides what language the sign-in wall is written
    // in — there is no second ask, and a miss costs the whole first launch its language. At 5 s it
    // died on a 7 KB/s link every time, queued behind the first-second catalog drain; the budget
    // is for a slow LINK, not for a slow Worker. Never awaited, so it delays nothing on screen.
    this._timeout = const Duration(seconds: 12),
  });

  final ApiClient _api;
  final SharedPreferences _prefs;
  final GeoAnswerHandler _onAnswer;
  final Duration _timeout;
  bool _asked = false;

  /// `main()`, once per process, before any UI -> only a fresh install's first process arms the ask.
  /// An update already holds a cohort draw -> never fresh -> an existing install is never re-languaged.
  static void markIfFreshInstall(
    SharedPreferences prefs, {
    required bool freshInstall,
  }) {
    if (freshInstall) unawaited(prefs.setBool(geoPendingPrefsKey, true));
  }

  Future<void> fetchOnce() async {
    if (_asked || !(_prefs.getBool(geoPendingPrefsKey) ?? false)) return;
    _asked = true;
    try {
      final answer = await _ask();
      debugPrint('[Geo] /geo answered $answer');
      final lang = answer['lang'];
      final region = answer['region'];
      await _onAnswer(
        lang: lang is String ? lang : null,
        region: region is String ? region : null,
      );
    } catch (error) {
      debugPrint('[Geo] no answer, asking again next cold start: $error');
    }
  }

  Future<Map<String, dynamic>> _ask() {
    // Test seam: `DEBUG_GEO_LANG=ta` stands in for the Worker -> the Tamil path walks on a phone in the north.
    // Const-gated on kDebugMode -> release builds compile it away.
    const debugLang = String.fromEnvironment('DEBUG_GEO_LANG');
    if (kDebugMode && debugLang.isNotEmpty) {
      return Future.value({'lang': debugLang, 'region': 'SEAM'});
    }
    return _api.get('/geo', requiresAuth: false).timeout(_timeout);
  }
}

@Riverpod(keepAlive: true)
GeoLanguageService geoLanguageService(Ref ref) => GeoLanguageService(
  api: ref.read(apiClientProvider),
  prefs: ref.read(sharedPreferencesProvider),
  onAnswer: ({lang, region}) =>
      ref.read(localeProvider.notifier).setGeoHint(lang: lang, region: region),
);
