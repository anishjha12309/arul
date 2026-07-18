import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'crash_reporter.dart';

/// Real [CrashReporter] backed by Firebase Crashlytics.
///
/// Assumes `Firebase.initializeApp()` + collection-enable already ran in
/// `main()` (every build except `flutter test`). Selected over
/// [NoOpCrashReporter] only when `AppConfig.firebaseEnabled` (see
/// `crash_provider.dart`), so the SDK is never touched uninitialised. All writes
/// are fire-and-forget — the SDK persists + uploads in the background, so we
/// never block the UI path.
class FirebaseCrashReporter implements CrashReporter {
  const FirebaseCrashReporter();

  FirebaseCrashlytics get _crashlytics => FirebaseCrashlytics.instance;

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) {
    unawaited(
      _crashlytics.recordError(error, stack, reason: reason, fatal: fatal),
    );
  }

  @override
  void setUserId(String? id) =>
      unawaited(_crashlytics.setUserIdentifier(id ?? ''));

  @override
  void log(String message) => _crashlytics.log(message);

  @override
  void setCustomKey(String key, Object value) =>
      unawaited(_crashlytics.setCustomKey(key, value));
}
