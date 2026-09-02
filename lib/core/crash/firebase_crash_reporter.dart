import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'crash_reporter.dart';

/// Real [CrashReporter] backed by Firebase Crashlytics.
///
/// `Firebase.initializeApp()` and collection-enable already ran in `main()` — every build but tests.
/// Selected over [NoOpCrashReporter] only when `AppConfig.firebaseEnabled` -> never touched cold.
/// The SDK persists and uploads in the background -> writes are fire-and-forget, never on the UI path.
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
