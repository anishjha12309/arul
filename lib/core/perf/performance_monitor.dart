/// Single interface for custom performance traces (Firebase Performance
/// Monitoring).
///
/// Perf auto-collects app-start + all HTTP/S network traces with NO code, which
/// already covers catalog/API/CDN latency. This abstraction is only for the few
/// custom traces worth measuring by hand (v1: wallpaper apply). Widgets must
/// never touch `FirebasePerformance` directly — depend on this behind
/// `performanceMonitorProvider`, so tests/debug builds get the no-op.
abstract interface class PerformanceMonitor {
  /// Starts (and returns) a running custom trace. Always pair with [PerfTrace.stop].
  Future<PerfTrace> startTrace(String name);
}

/// A single running trace. Stops the timer on [stop]; attributes/metrics added
/// before then are uploaded with it.
abstract interface class PerfTrace {
  /// Low-cardinality string dimension (e.g. result=success). Avoid unbounded
  /// values like ids — Perf caps attributes per trace.
  void putAttribute(String name, String value);

  /// Sets a numeric metric on the trace.
  void setMetric(String name, int value);

  /// Stops and submits the trace.
  Future<void> stop();
}

/// No-op used in debug builds and `flutter test`, where Firebase is never
/// initialised.
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
