/// Single interface for custom performance traces (Firebase Performance Monitoring).
///
/// Perf auto-collects app-start and every HTTP/S trace with NO code -> catalog, API and CDN latency
/// are already covered -> hand-write a trace only for what it misses (v1: wallpaper apply).
/// Never touch `FirebasePerformance` from a widget -> depend on this via `performanceMonitorProvider`,
/// which picks the no-op when Firebase is not initialised.
abstract interface class PerformanceMonitor {
  /// Starts (and returns) a running custom trace -> always pair with [PerfTrace.stop].
  Future<PerfTrace> startTrace(String name);
}

/// A single running trace -> attributes and metrics added before [stop] are uploaded with it.
abstract interface class PerfTrace {
  /// Low-cardinality string dimension (e.g. result=success) -> Perf caps attributes per trace ->
  /// never an unbounded value like an id.
  void putAttribute(String name, String value);

  void setMetric(String name, int value);

  /// Stops and submits the trace.
  Future<void> stop();
}

/// No-op for the only two cases where Firebase is never initialised: `flutter test`, and a build
/// without the `FIREBASE_ENABLED` define -> every real build (debug, profile, release) gets the real one.
class NoOpPerformanceMonitor implements PerformanceMonitor {
  const NoOpPerformanceMonitor();

  @override
  Future<PerfTrace> startTrace(String name) async => const NoOpPerfTrace();
}

class NoOpPerfTrace implements PerfTrace {
  const NoOpPerfTrace();

  @override
  void putAttribute(String name, String value) {}

  @override
  void setMetric(String name, int value) {}

  @override
  Future<void> stop() async {}
}
