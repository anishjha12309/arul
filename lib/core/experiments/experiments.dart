import 'dart:async';
import 'dart:math';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/repository_providers.dart';
import '../providers/shared_preferences_provider.dart';

part 'experiments.g.dart';

/// The arm an install was dealt while the regional A/B ran. The test is over: no new install is
/// dealt one, and a stored arm is kept only for analytics and the legacy language gate.
enum RegionalArm { control, regional }

/// Which UPI app heads the paywall picker for someone who has never picked one. `phonepe` is the
/// channel's own order; `paytm` floats Paytm above it (checkout.md: a reorder needs a split test).
enum UpiTopArm { phonepe, paytm }

final class Experiments {
  const Experiments({
    this.regional,
    this.regionalOff = false,
    this.upiTop,
    this.upiTopOff = false,
  });

  final RegionalArm? regional;

  final UpiTopArm? upiTop;

  /// `feature_flags.exp_upi_top` = false -> every arm gets the channel order from the next cold start.
  final bool upiTopOff;

  /// `feature_flags.exp_regional` = false, persisted when a config lands -> takes effect from the
  /// NEXT cold start, because the first launch has no config yet.
  final bool regionalOff;

  static const regionalKey = 'arul_exp_regional_v1';
  static const regionalOffKey = 'arul_exp_regional_off';
  static const upiTopKey = 'arul_exp_upi_top_v1';
  static const upiTopOffKey = 'arul_exp_upi_top_off';

  static const regionalProperty = 'exp_regional';
  static const upiTopProperty = 'exp_upi_top';

  static const regionalFlag = 'exp_regional';
  static const upiTopFlag = 'exp_upi_top';

  static const paytmPackage = 'net.one97.paytm';

  /// Every install gets the regional wall unless the kill switch is on.
  bool get regionalActive => !regionalOff;

  /// Whether a region language an older build stored still applies: only the installs that could
  /// have taken one (the regional arm, and installs that predate the draw) -> nobody's language flips.
  /// Keyed on the ARM, not [regionalActive]: a control install can hold a hint it never applied.
  bool get geoLanguageApplies =>
      regional == null || (regional == RegionalArm.regional && !regionalOff);

  /// The package the picker floats to the head before the remembered pick, or null for channel order.
  String? get upiLeadPackage =>
      upiTop == UpiTopArm.paytm && !upiTopOff ? paytmPackage : null;

  /// The assignment, never the kill state: the arm a person was dealt is what the read splits on.
  Map<String, Object> get analyticsProperties => {
    regionalProperty: ?regional?.name,
    upiTopProperty: ?upiTop?.name,
  };

  /// Once per install, on whichever launch first runs a build that has the test, so existing installs
  /// join too. Never re-dealt: a stored arm is read back as it is.
  ///
  /// [qaArm] (`QA_EXP_ARMS=paytm` on a sideload only) deals that arm instead of the coin.
  static void dealUpiTop(
    SharedPreferences prefs, {
    Random? random,
    String qaArm = '',
  }) {
    if (prefs.getString(upiTopKey) != null) return;
    final forced = _arm(UpiTopArm.values, qaArm.trim());
    final arm =
        forced ??
        UpiTopArm.values[(random ?? Random()).nextInt(UpiTopArm.values.length)];
    // Prefs caches synchronously -> `read` sees the arm at once; a failed disk write re-deals next
    // launch, before anything was shown, so it is still a fair coin.
    unawaited(prefs.setString(upiTopKey, arm.name));
  }

  static Experiments read(SharedPreferences prefs) => Experiments(
    regional: _arm(RegionalArm.values, prefs.getString(regionalKey)),
    regionalOff: prefs.getBool(regionalOffKey) ?? false,
    upiTop: _arm(UpiTopArm.values, prefs.getString(upiTopKey)),
    upiTopOff: prefs.getBool(upiTopOffKey) ?? false,
  );

  /// Persists the kill switch from a landed config. Only an explicit `false` turns the arm off, so a
  /// config that omits the key, or fails to load, never changes anything.
  static Future<void> persistKillSwitches(
    SharedPreferences prefs,
    Map<String, dynamic>? featureFlags,
  ) async {
    if (featureFlags == null) return;
    await Future.wait([
      prefs.setBool(regionalOffKey, featureFlags[regionalFlag] == false),
      prefs.setBool(upiTopOffKey, featureFlags[upiTopFlag] == false),
    ]);
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
