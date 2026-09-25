import 'dart:async';
import 'dart:math';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/repository_providers.dart';
import '../providers/shared_preferences_provider.dart';

part 'experiments.g.dart';

/// The regional wall's arm. `control` is today's app.
enum RegionalArm { control, regional }

/// A fresh install's coin flip, drawn once in `main()` and read back on every launch.
/// An install that predates the draw holds no arm and keeps today's app (analytics-events.md).
final class Experiments {
  const Experiments({this.regional, this.regionalOff = false});

  final RegionalArm? regional;

  /// `feature_flags.exp_regional` = false, persisted when a config lands -> takes effect from the
  /// NEXT cold start, because the first launch has no config yet.
  final bool regionalOff;

  static const regionalKey = 'arul_exp_regional_v1';
  static const regionalOffKey = 'arul_exp_regional_off';

  static const regionalProperty = 'exp_regional';

  static const regionalFlag = 'exp_regional';

  bool get regionalActive => regional == RegionalArm.regional && !regionalOff;

  /// Whether `/geo`'s language may choose the app's language: the regional arm, and installs that
  /// predate the draw (today's app). The control arm stores the region, never its language.
  bool get geoLanguageApplies => regional == null || regionalActive;

  /// The assignment, never the kill state: the arm a person was dealt is what the read splits on.
  Map<String, Object> get analyticsProperties => {
    regionalProperty: ?regional?.name,
  };

  /// Once per install, only in the process that created the cohort draw. Never re-drawn: a stored
  /// arm is read back as it is, so an update can never move a person between arms.
  ///
  /// [qaArms] (`QA_EXP_ARMS=regional` on a sideload only) deals the named arm instead of the coin,
  /// so each arm is walkable on a test phone with one `pm clear` per run.
  static void drawIfFreshInstall(
    SharedPreferences prefs, {
    required bool freshInstall,
    Random? random,
    String qaArms = '',
  }) {
    if (!freshInstall || prefs.getString(regionalKey) != null) return;
    final rng = random ?? Random();
    final forced = qaArms.split(',').map((a) => a.trim()).toSet();
    final regional = forced.contains(RegionalArm.regional.name)
        ? RegionalArm.regional
        : qaArms.isNotEmpty
        ? RegionalArm.control
        : RegionalArm.values[rng.nextInt(2)];
    // Prefs caches synchronously -> `read` sees the arm at once; a failed disk write re-draws next
    // launch, which is only ever the same fresh install and still a fair coin.
    unawaited(prefs.setString(regionalKey, regional.name));
  }

  static Experiments read(SharedPreferences prefs) => Experiments(
    regional: _arm(RegionalArm.values, prefs.getString(regionalKey)),
    regionalOff: prefs.getBool(regionalOffKey) ?? false,
  );

  /// Persists the kill switch from a landed config. Only an explicit `false` turns the arm off, so a
  /// config that omits the key, or fails to load, never changes anything.
  static Future<void> persistKillSwitches(
    SharedPreferences prefs,
    Map<String, dynamic>? featureFlags,
  ) async {
    if (featureFlags == null) return;
    await prefs.setBool(regionalOffKey, featureFlags[regionalFlag] == false);
  }

  static T? _arm<T extends Enum>(List<T> values, String? stored) {
    for (final v in values) {
      if (v.name == stored) return v;
    }
    return null;
  }
}

/// Read once per process: the arm never changes mid-run, and a kill switch waits for the next launch.
@Riverpod(keepAlive: true)
Experiments experiments(Ref ref) =>
    Experiments.read(ref.read(sharedPreferencesProvider));

/// Writes the kill switch whenever a config lands. Started from the splash; keepAlive so a config
/// that arrives after the splash has routed is still recorded.
@Riverpod(keepAlive: true)
void experimentKillSwitch(Ref ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  ref.listen(appConfigProvider, (_, next) {
    final flags = next.asData?.value?.featureFlags;
    if (flags != null) unawaited(Experiments.persistKillSwitches(prefs, flags));
  }, fireImmediately: true);
}
