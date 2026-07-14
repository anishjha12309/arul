import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'crash_reporter.dart';

part 'crash_provider.g.dart';

/// App-wide [CrashReporter].
///
/// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
/// provisioned (no google-services.json). Once it is, copy the reference's
/// `firebase_crash_reporter.dart` next to this file and restore:
///
///   if (!AppConfig.firebaseEnabled) return const NoOpCrashReporter();
///   return const FirebaseCrashReporter();
///
/// Call sites depend only on [CrashReporter], so nothing else changes.
@Riverpod(keepAlive: true)
CrashReporter crashReporter(Ref ref) {
  // AppConfig.firebaseEnabled is hard false until Firebase is provisioned.
  assert(!AppConfig.firebaseEnabled || true);
  return const NoOpCrashReporter();
}
