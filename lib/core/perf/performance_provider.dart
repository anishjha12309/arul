import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'firebase_performance_monitor.dart';
import 'performance_monitor.dart';

part 'performance_provider.g.dart';

/// App-wide [PerformanceMonitor]. Returns the real Firebase implementation in
/// every real app build (debug, profile, release), and the no-op under
/// `flutter test` — same `AppConfig.firebaseEnabled` guard as `main()` and
/// `crashReporterProvider`, so tests never touch an uninitialised SDK.
@Riverpod(keepAlive: true)
PerformanceMonitor performanceMonitor(Ref ref) {
  if (!AppConfig.firebaseEnabled) return const NoOpPerformanceMonitor();
  return const FirebasePerformanceMonitor();
}
