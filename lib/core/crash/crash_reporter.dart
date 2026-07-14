/// Single interface for crash + non-fatal error reporting (Firebase Crashlytics).
///
/// Kept SEPARATE from [AnalyticsService] (product analytics): a crash reporter
/// answers "did it break, and where", analytics answers "what did the user do".
/// Widgets must never touch `FirebaseCrashlytics` directly — depend on this
/// behind `crashReporterProvider`, so tests/debug builds get the no-op.
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

/// No-op used in debug builds and `flutter test`, where Firebase is never
/// initialised. Every method is a safe no-op so call sites never branch.
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
