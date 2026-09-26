import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/router.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/analytics/analytics_service.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/build_info.dart';
import '../../../core/providers/package_info_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../../core/update/update_holds.dart';
import '../../../data/models/app_config_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../ringtones/providers/ringtone_set_provider.dart';
import '../../wallpapers/providers/wallpaper_apply_provider.dart';
import '../../wallpapers/providers/wallpaper_share_provider.dart';
import '../data/app_update_client.dart';
import '../domain/app_update_policy.dart';

part 'app_update_controller.g.dart';

/// Watched at the app root -> the update check never depends on a screen being opened.
@Riverpod(keepAlive: true)
void appUpdateBootstrap(Ref ref) {
  if (AppConfig.isFlutterTest) return;
  final client = AppUpdateClient();
  final controller = AppUpdateController(
    client: client,
    analytics: ref.read(analyticsServiceProvider),
    prefs: ref.read(sharedPreferencesProvider),
    readConfig: () => ref.read(appConfigProvider.future),
    readInstalledBuild: () async =>
        int.tryParse(
          (await ref.read(packageInfoProvider.future)).buildNumber,
        ) ??
        0,
    routeChanges: router.routerDelegate,
    location: () => router.routerDelegate.currentConfiguration.uri.path,
    // A restart mid-apply or mid-set loses it, and the live chooser hides us -> held while loading.
    hostBusy: () =>
        ref.read(wallpaperApplyProvider) is WallpaperApplyLoading ||
        ref.read(wallpaperShareProvider) is WallpaperSharePreparing ||
        ref.read(ringtoneSetProvider) is RingtoneSetLoading,
  );
  ref.onDispose(controller.dispose);
  UpdateHolds.launch.value = UpdateLaunch.undecided;
  // Sideloads and debug installs are not Play-owned -> the API only ever errors there, unless the
  // test hook put Play's fake manager behind the channel.
  unawaited(() async {
    if (PlayInstall.isPlay || await client.isFake()) {
      controller.start();
    } else {
      UpdateHolds.launch.value = UpdateLaunch.clear;
    }
  }());
}

/// When to ask Play, and when never to: docs/app-update.md.
class AppUpdateController {
  AppUpdateController({
    required this.client,
    required this.analytics,
    required this.prefs,
    required this.readConfig,
    required this.readInstalledBuild,
    required this.routeChanges,
    required this.location,
    bool Function()? hostBusy,
    DateTime Function()? now,
  }) : _hostBusy = hostBusy ?? _never,
       _now = now ?? DateTime.now;

  static bool _never() => false;

  final AppUpdateClient client;
  final AnalyticsService analytics;
  final SharedPreferences prefs;
  final Future<AppConfigModel?> Function() readConfig;
  final Future<int> Function() readInstalledBuild;
  final Listenable routeChanges;
  final String Function() location;
  final bool Function() _hostBusy;
  final DateTime Function() _now;

  static const _declinedAtKey = 'arul_update_declined_at';
  static const _flexibleStartedKey = 'arul_update_flexible_started';
  // The splash and the sign-in wall are never covered (docs/auth.md) -> checks wait for the feed.
  static const _neverOver = {'/', '/sign-in'};
  // Past the splash, autoSignIn has already taken its hold -> the check cannot beat the sheet.
  static const _launchSettle = Duration(milliseconds: 1500);
  static const _holdSettle = Duration(seconds: 2);
  static const _resumeAway = Duration(seconds: 60);
  // Returning from Play's own screen is a resume too -> without this a cancel re-prompts forever.
  static const _ownFlowEcho = Duration(seconds: 5);

  AppLifecycleListener? _lifecycle;
  StreamSubscription<String>? _installSub;
  Timer? _timer;
  UpdateTrigger? _pending;
  DateTime? _awaySince;
  DateTime? _flowEndedAt;
  bool _launched = false;
  bool _busy = false;
  bool _downloaded = false;

  void start() {
    _installSub = client.installStates.listen((status) {
      if (status == 'downloaded') _downloaded = true;
    });
    _lifecycle = AppLifecycleListener(onHide: _onHide, onResume: _onResume);
    UpdateHolds.active.addListener(_onHolds);
    routeChanges.addListener(_onRoute);
    _onRoute();
  }

  void dispose() {
    _timer?.cancel();
    _launchDecided(prompted: false);
    _installSub?.cancel();
    _lifecycle?.dispose();
    UpdateHolds.active.removeListener(_onHolds);
    routeChanges.removeListener(_onRoute);
    client.dispose();
  }

  void _onRoute() {
    if (!_launched) {
      if (location() == '/') return;
      _launched = true;
      _schedule(UpdateTrigger.coldStart, _launchSettle);
      return;
    }
    final pending = _pending;
    if (pending != null && !_busy && _clear) _schedule(pending, _holdSettle);
  }

  void _launchDecided({required bool prompted}) {
    if (UpdateHolds.launch.value != UpdateLaunch.undecided) return;
    UpdateHolds.launch.value = prompted
        ? UpdateLaunch.prompted
        : UpdateLaunch.clear;
  }

  void _onHolds() {
    final pending = _pending;
    if (UpdateHolds.active.value == 0 && pending != null) {
      _schedule(pending, _holdSettle);
    }
  }

  void _onHide() {
    _awaySince ??= _now();
    // A backgrounded completeUpdate installs silently (Play docs) -> no restart prompt of ours.
    if (_downloaded &&
        !_busy &&
        UpdateHolds.active.value == 0 &&
        !_hostBusy()) {
      _downloaded = false;
      unawaited(client.completeUpdate());
    }
  }

  void _onResume() {
    final away = _awaySince;
    _awaySince = null;
    if (_busy) return;
    // A check deferred by a system dialog (the notification ask right after sign-in) only ever
    // saw `inactive` -> no hold drops and no away time, so nothing else would retry it.
    final pending = _pending;
    if (pending != null) {
      _schedule(pending, _holdSettle);
      return;
    }
    if (away == null) return;
    final ended = _flowEndedAt;
    if (ended != null && _now().difference(ended) < _ownFlowEcho) return;
    if (_now().difference(away) < _resumeAway) return;
    _schedule(UpdateTrigger.resume, _holdSettle);
  }

  void _schedule(UpdateTrigger trigger, Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_evaluate(trigger)));
  }

  // Google's sign-in sheet and system dialogs leave us `inactive` -> only `resumed` is clear.
  bool get _clear =>
      UpdateHolds.active.value == 0 &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      !_neverOver.contains(location()) &&
      !_hostBusy();

  void _defer(UpdateTrigger trigger) {
    _pending = trigger;
    // An apply or set finishing notifies nothing -> poll only while that is the one blocker.
    if (UpdateHolds.active.value == 0 &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        !_neverOver.contains(location())) {
      _schedule(trigger, _holdSettle);
    }
  }

  Future<void> _evaluate(UpdateTrigger trigger) async {
    if (_busy) return;
    if (!_clear) {
      _defer(trigger);
      return;
    }
    _pending = null;
    _busy = true;
    var prompted = false;
    try {
      final info = await client.check();
      if (info.error != null) return;
      if (info.installStatus == 'downloaded') {
        _downloaded = true;
        return;
      }
      if (info.availability == UpdateAvailability.none) {
        await prefs.remove(_flexibleStartedKey);
      }
      AppConfigModel? config;
      try {
        config = await readConfig().timeout(const Duration(seconds: 10));
      } catch (_) {
        config = null;
      }
      final installed = await readInstalledBuild();
      final minBuild = parseMinBuild(config?.minSupportedVersion);
      final declinedRaw = prefs.getString(_declinedAtKey);
      final action = decide(
        info: info,
        flags: UpdateFlags.from(config?.featureFlags),
        installedBuild: installed,
        minBuild: minBuild,
        trigger: trigger,
        now: _now(),
        declinedAt: declinedRaw == null ? null : DateTime.tryParse(declinedRaw),
        flexibleStarted: prefs.getBool(_flexibleStartedKey) ?? false,
      );
      if (action == UpdateAction.none) return;
      if (!_clear) {
        _defer(trigger);
        return;
      }
      prompted = true;
      _launchDecided(prompted: true);
      final immediate = action != UpdateAction.flexible;
      final props = <String, Object?>{
        'type': immediate ? 'immediate' : 'flexible',
        'trigger': trigger.name,
        'installed_build': '${buildOf(installed)}',
        'available_build': '${info.availableBuild}',
        'forced': minBuild != null && buildOf(installed) < minBuild
            ? 'yes'
            : 'no',
      };
      analytics.track('app_update_prompt', properties: props);
      final result = await client.start(immediate: immediate);
      _flowEndedAt = _now();
      if (result == 'cancelled') {
        await prefs.setString(_declinedAtKey, _now().toIso8601String());
      }
      await prefs.setBool(
        _flexibleStartedKey,
        !immediate && result == 'accepted',
      );
      analytics.track(
        'app_update_result',
        properties: {...props, 'result': result},
      );
    } catch (e) {
      // Never let an update check surface as an error: the app carries on without it.
      debugPrint('[AppUpdate] check failed: $e');
    } finally {
      _busy = false;
      if (!prompted && _pending == null) _launchDecided(prompted: false);
    }
  }
}
