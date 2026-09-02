import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'firebase_performance_monitor.dart';
import 'performance_monitor.dart';

part 'performance_provider.g.dart';

/// App-wide [PerformanceMonitor] — real Firebase in every app build, the no-op under `flutter test`.
/// The same `AppConfig.firebaseEnabled` guard as `main()` -> tests never touch an uninitialised SDK.
@Riverpod(keepAlive: true)
PerformanceMonitor performanceMonitor(Ref ref) {
  if (!AppConfig.firebaseEnabled) return const NoOpPerformanceMonitor();
  return const FirebasePerformanceMonitor();
}
