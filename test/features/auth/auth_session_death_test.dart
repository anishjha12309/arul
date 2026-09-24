// A session that dies MID-PROCESS must end the signed-in state, exactly as a cold start's /me 401
// does. Crashlytics: `no_refresh_token` after a dead refresh, the UI still "signed in" and every
// apply, checkout and /me failing until the next cold start.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';
import 'package:arul/features/auth/domain/auth_service.dart';

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

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'arul_access_token': 'acc',
      'arul_refresh_token': 'ref',
    }),
  );

  test('a refresh that dies mid-process signs the UI out, once', () async {
    var sessionAlive = true;
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path == '/me' && sessionAlive) {
          return _json({
            'user': {'id': 'u1', 'displayName': 'A', 'email': 'a@x'},
          }, 200);
        }
        if (req.url.path == '/auth/refresh') {
          return _json({
            'error': {'code': 'invalid_refresh', 'message': 'no'},
          }, 401);
        }
        return _json({
          'error': {'code': 'unauthorized', 'message': 'x'},
        }, 401);
      }),
    );
    final auth = ApiAuthService(
      apiClient: api,
      analytics: _SilentAnalytics(),
      crash: const NoOpCrashReporter(),
      freshInstall: false,
    );
    await auth.initialized;
    expect(auth.currentState.isAuthenticated, isTrue);

    final states = <AuthUserState>[];
    final sub = auth.authStateChanges.listen(states.add);

    // The refresh token dies server-side; the next gated call finds out.
    sessionAlive = false;
    await expectLater(
      api.post('/payments/status'),
      throwsA(isA<ApiException>().having((e) => e.isSessionExpired, 'x', true)),
    );
    await Future<void>.delayed(Duration.zero);

    expect(auth.currentState.isAuthenticated, isFalse);
    expect(states.where((s) => !s.isAuthenticated), hasLength(1));

    // A second gated call on the dead session changes nothing more.
    await expectLater(
      api.post('/payments/status'),
      throwsA(isA<ApiException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(states.where((s) => !s.isAuthenticated), hasLength(1));
    await sub.cancel();
  });
}
