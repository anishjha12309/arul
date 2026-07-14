import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../config/app_config.dart';
import 'performance_monitor.dart';

part 'performance_provider.g.dart';

/// App-wide [PerformanceMonitor].
///
/// FIREBASE-REENABLE: currently ALWAYS the no-op because Firebase is not
/// provisioned (no google-services.json). Once it is, copy the reference's
/// `firebase_performance_monitor.dart` next to this file and restore:
///
///   if (!AppConfig.firebaseEnabled) return const NoOpPerformanceMonitor();
///   return const FirebasePerformanceMonitor();
@Riverpod(keepAlive: true)
PerformanceMonitor performanceMonitor(Ref ref) {
  assert(!AppConfig.firebaseEnabled || true);
  return const NoOpPerformanceMonitor();
}
