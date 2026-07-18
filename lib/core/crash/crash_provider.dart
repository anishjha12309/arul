import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'crash_reporter.dart';
import 'firebase_crash_reporter.dart';

part 'crash_provider.g.dart';

/// App-wide [CrashReporter]. Returns the real Crashlytics implementation in
/// every real app build (debug, profile, release), and the no-op under
/// `flutter test`.
///
/// Crashlytics is only initialised in `main()` when `AppConfig.firebaseEnabled`
/// (google-services.json present + FIREBASE_ENABLED=true), so the same guard
/// here keeps `flutter test` and unprovisioned builds from touching an
/// uninitialised SDK. Call sites never change.
@Riverpod(keepAlive: true)
CrashReporter crashReporter(Ref ref) {
  if (!AppConfig.firebaseEnabled) return const NoOpCrashReporter();
  return const FirebaseCrashReporter();
}
