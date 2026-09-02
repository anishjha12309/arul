import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'crash_reporter.dart';
import 'firebase_crash_reporter.dart';

part 'crash_provider.g.dart';

/// App-wide [CrashReporter] — real Crashlytics in every real build, the no-op under `flutter test`.
///
/// `main()` only initialises Crashlytics when `AppConfig.firebaseEnabled` -> the same guard here
/// keeps tests and unprovisioned builds off an uninitialised SDK.
@Riverpod(keepAlive: true)
CrashReporter crashReporter(Ref ref) {
  if (!AppConfig.firebaseEnabled) return const NoOpCrashReporter();
  return const FirebaseCrashReporter();
}
