import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/providers/auth_providers.dart';
import '../analytics/journey_stamps.dart';
import '../api/api_client.dart';
import '../config/build_info.dart';
import '../perf/boot_trace.dart';
import 'locale_provider.dart';
import 'shared_preferences_provider.dart';

part 'geo_region_service.g.dart';

/// A FRESH install's region, asked ONCE -> the Worker answers from Cloudflare's `request.cf`.
/// The region picks the launch poster and the come-back picture, never the language.
/// At most ONE request per process whatever happens -> no retry loop can ever come from here.
class GeoRegionService {
  GeoRegionService({
    required this._api,
    required this._prefs,
    required this._onRegion,
    this._timeout = const Duration(seconds: 12),
  });

  final ApiClient _api;
  final SharedPreferences _prefs;
  final void Function() _onRegion;
  final Duration _timeout;
  bool _asked = false;
  final _settled = Completer<void>();

  /// Completes once this process's ask has an answer or a failure, or at once when there is none to
  /// make -> a reader that needs the region waits here instead of reading prefs too early.
  Future<void> get settled => _settled.future;

  /// Whether [fetchOnce] will reach the Worker -> the splash lets it stand in for the warm-up.
  bool get willAsk => !_asked && (_prefs.getBool(geoPendingPrefsKey) ?? false);

  /// `main()`, once per process, before any UI -> only a fresh install's first process arms the ask.
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
    JourneyStamps.noteGeo('pending');
    final clock = Stopwatch()..start();
    try {
      final answer = await _ask();
      final ms = clock.elapsedMilliseconds;
      BootTrace.mark('geo: answered in ${ms}ms');
      debugPrint('[Geo] /geo answered $answer');
      _api.noteWarmUp(ms);
      JourneyStamps.noteGeo('answered', ms: ms);
      final region = answer['region'];
      await Future.wait([
        _prefs.setString(
          geoRegionPrefsKey,
          region is String && region.isNotEmpty ? region : geoNone,
        ),
        _prefs.remove(geoPendingPrefsKey),
      ]);
      _onRegion();
    } catch (error) {
      final ms = clock.elapsedMilliseconds;
      BootTrace.mark('geo: no answer after ${ms}ms');
      debugPrint('[Geo] no answer, asking again next cold start: $error');
      _api.noteWarmUp(ms);
      JourneyStamps.noteGeo('failed', ms: ms);
    } finally {
      _settled.complete();
    }
  }

  Future<Map<String, dynamic>> _ask() {
    // Const-gated on the define -> a build without it compiles the seam away; a sideload release
    // may carry it (never a Play install), so each regional poster is walkable at release speed.
    const debugRegion = String.fromEnvironment('DEBUG_GEO_REGION');
    if (debugRegion.isNotEmpty && (kDebugMode || !PlayInstall.isPlay)) {
      return Future.value({'region': debugRegion});
    }
    // No token: the keystore's single worker thread is still busy with main()'s first read.
    return _api
        .get('/geo', requiresAuth: false, withToken: false)
        .timeout(_timeout);
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
GeoRegionService geoRegionService(Ref ref) => GeoRegionService(
  api: ref.read(apiClientProvider),
  prefs: ref.read(sharedPreferencesProvider),
  onRegion: () => ref.invalidate(languageOriginProvider),
);
