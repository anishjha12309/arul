import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/providers/auth_providers.dart';
import '../api/api_client.dart';
import '../config/build_info.dart';
import '../perf/boot_trace.dart';
import 'locale_provider.dart';
import 'shared_preferences_provider.dart';

part 'geo_language_service.g.dart';

typedef GeoAnswerHandler =
    Future<void> Function({String? lang, String? region, bool applyLive});

/// A FRESH install's region hint, asked ONCE -> the Worker answers from Cloudflare's `request.cf`.
///
/// Fired from the splash beside `warmUp()`. Only the regional arm awaits it, under a cap
/// (launch-surface.md); every other launch routes on the auth seed alone.
/// Offline, timed out or not live yet -> nothing stored, pending kept -> the next cold start asks again.
/// At most ONE request per process whatever happens -> no retry loop can ever come from here.
class GeoLanguageService {
  GeoLanguageService({
    required this._api,
    required this._prefs,
    required this._onAnswer,
    this._timeout = const Duration(seconds: 12),
  });

  final ApiClient _api;
  final SharedPreferences _prefs;
  final GeoAnswerHandler _onAnswer;
  final Duration _timeout;
  bool _asked = false;
  bool _live = true;
  final _settled = Completer<void>();

  /// Completes once this process's ask has an answer or a failure, or at once when there is none to
  /// make -> a reader that needs the region waits here instead of reading prefs too early.
  Future<void> get settled => _settled.future;

  /// The regional arm's cap has passed -> a later answer is stored for the NEXT launch, never applied
  /// to this one: a wall that painted in one language must not flip to another.
  void closeLiveWindow() => _live = false;

  /// `main()`, once per process, before any UI -> only a fresh install's first process arms the ask.
  /// An update already holds a cohort draw -> never fresh -> an existing install is never re-languaged.
  static void markIfFreshInstall(
    SharedPreferences prefs, {
    required bool freshInstall,
  }) {
    if (freshInstall) unawaited(prefs.setBool(geoPendingPrefsKey, true));
  }

  Future<void> fetchOnce() async {
    if (_asked) return;
    _asked = true;
    if (!(_prefs.getBool(geoPendingPrefsKey) ?? false)) {
      _settled.complete();
      return;
    }
    final clock = Stopwatch()..start();
    try {
      final answer = await _ask();
      BootTrace.mark('geo: answered in ${clock.elapsedMilliseconds}ms');
      debugPrint('[Geo] /geo answered $answer');
      final lang = answer['lang'];
      final region = answer['region'];
      await _onAnswer(
        lang: lang is String ? lang : null,
        region: region is String ? region : null,
        applyLive: _live,
      );
    } catch (error) {
      BootTrace.mark('geo: no answer after ${clock.elapsedMilliseconds}ms');
      debugPrint('[Geo] no answer, asking again next cold start: $error');
    } finally {
      _settled.complete();
    }
  }

  Future<Map<String, dynamic>> _ask() {
    // Test seam: `DEBUG_GEO_LANG=ta` stands in for the Worker -> the Tamil path walks on a phone in the north.
    // Const-gated on the define -> a build without it compiles the seam away; a sideload release
    // may carry it (never a Play install), so the regional wall is walkable at release speed.
    // `DEBUG_GEO_REGION=KL` picks the regional arm's art the same way.
    const debugLang = String.fromEnvironment('DEBUG_GEO_LANG');
    const debugRegion = String.fromEnvironment(
      'DEBUG_GEO_REGION',
      defaultValue: 'SEAM',
    );
    if (debugLang.isNotEmpty && (kDebugMode || !PlayInstall.isPlay)) {
      return Future.value({'lang': debugLang, 'region': debugRegion});
    }
    // `v=2` is what earns a `lang` -> builds before the factorial flip nothing, so its cohort stays clean.
    return _api.get('/geo?v=2', requiresAuth: false).timeout(_timeout);
  }
}

/// The regional arm's wait: true when [ask] settled within [remaining], false at the cap. Never
/// throws — `fetchOnce` swallows its own failures, and a failure is "no answer" here too.
Future<bool> awaitRegionAnswer(Future<void> ask, Duration remaining) async {
  var settled = false;
  final tracked = ask.then<void>((_) => settled = true, onError: (Object _) {});
  if (remaining > Duration.zero) {
    await tracked.timeout(remaining, onTimeout: () {});
  }
  return settled;
}

@Riverpod(keepAlive: true)
GeoLanguageService geoLanguageService(Ref ref) => GeoLanguageService(
  api: ref.read(apiClientProvider),
  prefs: ref.read(sharedPreferencesProvider),
  onAnswer: ({lang, region, applyLive = true}) => ref
      .read(localeProvider.notifier)
      .setGeoHint(lang: lang, region: region, applyLive: applyLive),
);
