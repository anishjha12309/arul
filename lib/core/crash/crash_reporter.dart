/// Single interface for crash + non-fatal error reporting (Firebase Crashlytics).
///
/// Kept SEPARATE from [AnalyticsService] (product analytics): a crash reporter
/// answers "did it break, and where", analytics answers "what did the user do".
/// Widgets must never touch `FirebaseCrashlytics` directly — depend on this
/// behind `crashReporterProvider`, which picks the no-op when Firebase is not
/// initialised.
abstract interface class CrashReporter {
  /// Records a caught (non-fatal by default) error. Use at catch sites that
  /// currently swallow meaningful failures — NOT in hot loops.
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal,
  });

  /// Associates subsequent reports with a user id (the auth `sub`). Pass null to
  /// clear it on sign-out.
  void setUserId(String? id);

  /// Adds a breadcrumb line to the next crash report.
  void log(String message);

  /// Attaches a key/value shown alongside the next crash report.
  void setCustomKey(String key, Object value);
}

/// No-op used ONLY under `flutter test`, or in a build without the
/// `FIREBASE_ENABLED` define — the two cases where Firebase is never
/// initialised. Every real build (debug, profile and release) gets the real
/// Crashlytics reporter. Every method is a safe no-op so call sites never
/// branch.
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
