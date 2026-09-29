// The wall hides its box while Google's surface is up (sign_in_screen.dart). A stall-guard abandon is
// the one exit whose zombie never clears that flag itself (its finally is identity-checked), so the
// abandon must clear it -> otherwise the wall stays empty with no pill to tap.

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a stall-guard abandon brings the wall back', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final auth = ApiAuthService(
      apiClient: ApiClient(),
      analytics: _SilentAnalytics(),
      crash: const NoOpCrashReporter(),
      freshInstall: true,
    );
    await auth.initialized;
    addTearDown(() => SignInPhase.surfaceUp.value = false);

    SignInPhase.surfaceUp.value = true;
    auth.abandonPendingSignIn();

    expect(SignInPhase.surfaceUp.value, isFalse);
  });
}
