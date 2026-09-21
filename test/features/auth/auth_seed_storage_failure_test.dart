// The stored-session check must never strand the splash.
//
// Crashlytics: Android Keystore "Failed to generate key pair" out of `ApiClient.hasTokens`, six
// events per affected user on low-RAM Android 9 phones. The throw failed `AuthService.initialized`,
// the splash's `await initialized` threw before its `context.go`, and the app sat on the splash on
// every launch. An unreadable session is the same verdict as no session -> the wall.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';

class _SilentAnalytics implements AnalyticsService {
  @override
  void track(String event, {Map<String, Object?>? properties}) {}

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}

class _RecordingCrash extends NoOpCrashReporter {
  final reasons = <String?>[];

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) => reasons.add(reason);
}

class _BrokenKeystoreApi extends ApiClient {
  @override
  Future<bool> hasTokens() async => throw PlatformException(
    code: 'Exception encountered',
    message: 'java.security.ProviderException: Failed to generate key pair',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unreadable keystore settles the seed as signed out', () async {
    final crash = _RecordingCrash();
    final auth = ApiAuthService(
      apiClient: _BrokenKeystoreApi(),
      analytics: _SilentAnalytics(),
      crash: crash,
      // A returning launch -> the seed actually reads the store.
      freshInstall: false,
    );

    // The splash awaits exactly this. It used to complete with the PlatformException.
    await expectLater(auth.initialized, completes);
    expect(auth.currentState.isAuthenticated, isFalse);
    expect(crash.reasons, ['auth seed: secure storage read']);
  });
}
