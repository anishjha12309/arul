/// Single interface for crash + non-fatal error reporting (Firebase Crashlytics).
///
/// Kept SEPARATE from analytics: this answers "did it break, and where", analytics "what did they do".
/// Widgets must NEVER touch `FirebaseCrashlytics` -> depend on `crashReporterProvider` instead.
/// That provider picks the no-op when Firebase is not initialised.
abstract interface class CrashReporter {
  /// Records a caught error, non-fatal by default — for catch sites that swallow real failures.
  /// NOT for hot loops.
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal,
  });

  /// Associates later reports with a user id (the auth `sub`). Null clears it on sign-out.
  void setUserId(String? id);

  /// Adds a breadcrumb line to the next crash report.
  void log(String message);

  /// Attaches a key/value shown alongside the next crash report.
  void setCustomKey(String key, Object value);
}

/// No-op for the two cases Firebase is never initialised: `flutter test`, and no `FIREBASE_ENABLED`.
/// Every real build — debug, profile, release — gets the real Crashlytics reporter.
/// Every method is a safe no-op -> call sites never branch.
class NoOpCrashReporter implements CrashReporter {
  const NoOpCrashReporter();

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) {}

  @override
  void setUserId(String? id) {}

  @override
  void log(String message) {}

  @override
  void setCustomKey(String key, Object value) {}
}
