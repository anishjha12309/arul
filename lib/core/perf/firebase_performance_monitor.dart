import 'package:firebase_performance/firebase_performance.dart';

import 'performance_monitor.dart';

/// Real [PerformanceMonitor] backed by Firebase Performance Monitoring.
///
/// Assumes Firebase was initialised + perf collection enabled in `main()`
/// (every build except `flutter test`). Selected over [NoOpPerformanceMonitor]
/// only when `AppConfig.firebaseEnabled` (see `performance_provider.dart`).
class FirebasePerformanceMonitor implements PerformanceMonitor {
  const FirebasePerformanceMonitor();

  @override
  Future<PerfTrace> startTrace(String name) async {
    final trace = FirebasePerformance.instance.newTrace(name);
    await trace.start();
    return _FirebasePerfTrace(trace);
  }
}

class _FirebasePerfTrace implements PerfTrace {
  _FirebasePerfTrace(this._trace);

  final Trace _trace;

  @override
  void putAttribute(String name, String value) =>
      _trace.putAttribute(name, value);

  @override
  void setMetric(String name, int value) => _trace.setMetric(name, value);

  @override
  Future<void> stop() => _trace.stop();
}
