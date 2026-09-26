enum UpdateAvailability { available, inProgress, none, unknown }

enum UpdateTrigger { coldStart, resume, holdRelease }

enum UpdateAction { none, immediate, flexible, resumeImmediate }

final class UpdateInfo {
  const UpdateInfo({
    required this.availability,
    this.availableBuild = 0,
    this.immediateAllowed = false,
    this.flexibleAllowed = false,
    this.installStatus = 'unknown',
  }) : error = null;

  const UpdateInfo.unavailable(String this.error)
    : availability = UpdateAvailability.unknown,
      availableBuild = 0,
      immediateAllowed = false,
      flexibleAllowed = false,
      installStatus = 'unknown';

  factory UpdateInfo.fromMap(Map<String, Object?> map) => UpdateInfo(
    availability: switch (map['availability']) {
      'available' => UpdateAvailability.available,
      'in_progress' => UpdateAvailability.inProgress,
      'none' => UpdateAvailability.none,
      _ => UpdateAvailability.unknown,
    },
    availableBuild: (map['availableBuild'] as int?) ?? 0,
    immediateAllowed: map['immediateAllowed'] == true,
    flexibleAllowed: map['flexibleAllowed'] == true,
    installStatus: (map['installStatus'] as String?) ?? 'unknown',
  );

  final UpdateAvailability availability;
  final int availableBuild;
  final bool immediateAllowed;
  final bool flexibleAllowed;
  final String installStatus;
  final String? error;
}

enum UpdateMode { immediate, flexible, off }

/// `feature_flags.app_update` from the catalog's app_config (CMS "Advanced settings").
final class UpdateFlags {
  const UpdateFlags({
    this.mode = UpdateMode.immediate,
    this.reprompt = const Duration(minutes: 30),
  });

  factory UpdateFlags.from(Map<String, dynamic>? featureFlags) {
    final raw = featureFlags?['app_update'];
    if (raw is! Map) return const UpdateFlags();
    final minutes = raw['reprompt_minutes'];
    return UpdateFlags(
      mode: switch (raw['mode']) {
        'flexible' => UpdateMode.flexible,
        'off' => UpdateMode.off,
        _ => UpdateMode.immediate,
      },
      reprompt: minutes is int && minutes >= 0
          ? Duration(minutes: minutes)
          : const Duration(minutes: 30),
    );
  }

  final UpdateMode mode;
  final Duration reprompt;
}

/// app_config.min_supported_version read as a build number: '85' or '1.0.0+85' -> 85.
/// Anything else (the live '1.0.0', blank, junk) is no floor, so an old value never forces.
int? parseMinBuild(String? raw) {
  if (raw == null) return null;
  final tail = raw.trim().split('+').last;
  if (!RegExp(r'^\d{1,4}$').hasMatch(tail)) return null;
  return int.parse(tail);
}

/// Split-per-abi sideloads carry 2084-style codes -> the build is the last three digits.
int buildOf(int versionCode) => versionCode % 1000;

UpdateAction decide({
  required UpdateInfo info,
  required UpdateFlags flags,
  required int installedBuild,
  required UpdateTrigger trigger,
  required DateTime now,
  int? minBuild,
  DateTime? declinedAt,
  bool flexibleStarted = false,
}) {
  // Play reports a FLEXIBLE download as in progress too -> resuming it as IMMEDIATE would throw a
  // full-screen update over someone who chose to keep using the app.
  if (info.availability == UpdateAvailability.inProgress) {
    return flexibleStarted ? UpdateAction.none : UpdateAction.resumeImmediate;
  }
  if (info.availability != UpdateAvailability.available) {
    return UpdateAction.none;
  }
  final belowFloor = minBuild != null && buildOf(installedBuild) < minBuild;
  // Below the floor the CMS knob and the decline cooldown no longer apply: every check prompts.
  if (belowFloor) {
    if (info.immediateAllowed) return UpdateAction.immediate;
    if (info.flexibleAllowed) return UpdateAction.flexible;
    return UpdateAction.none;
  }
  if (flags.mode == UpdateMode.off) return UpdateAction.none;
  if (trigger != UpdateTrigger.coldStart &&
      declinedAt != null &&
      now.difference(declinedAt) < flags.reprompt) {
    return UpdateAction.none;
  }
  if (flags.mode == UpdateMode.immediate && info.immediateAllowed) {
    return UpdateAction.immediate;
  }
  if (info.flexibleAllowed) return UpdateAction.flexible;
  return UpdateAction.none;
}
