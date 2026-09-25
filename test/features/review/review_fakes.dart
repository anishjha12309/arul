import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/review/data/review_launcher.dart';

class FakeReviewLauncher implements ReviewLauncher {
  bool available = true;
  Object? availabilityError;
  Object? requestError;
  int availabilityChecks = 0;
  int requests = 0;

  @override
  Future<bool> isAvailable() async {
    availabilityChecks++;
    final e = availabilityError;
    if (e != null) throw e;
    return available;
  }

  @override
  Future<void> requestReview() async {
    final e = requestError;
    if (e != null) throw e;
    requests++;
  }
}

class RecordingAnalytics implements AnalyticsService {
  final events = <String>[];
  final props = <String, Map<String, Object?>>{};

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    events.add(event);
    if (properties != null) props[event] = properties;
  }

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}

class RecordingCrash implements CrashReporter {
  final errors = <Object>[];
  final fatal = <bool>[];

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) {
    errors.add(error);
    this.fatal.add(fatal);
  }

  @override
  void log(String message) {}

  @override
  void setCustomKey(String key, Object value) {}

  @override
  void setUserId(String? id) {}
}
