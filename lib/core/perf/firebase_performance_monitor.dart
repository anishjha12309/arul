import 'package:firebase_performance/firebase_performance.dart';

import 'performance_monitor.dart';

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
