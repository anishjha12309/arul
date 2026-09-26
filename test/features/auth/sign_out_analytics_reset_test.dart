// Sign-out and account deletion clear every analytics identity BEFORE the sign-in wall appears, so
// the next person's pre-login events never land on the previous user (Meta app_user_id, PostHog
// distinct_id, GA4 user_id). Account deletion still reports `account_deleted` as the departing user.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/auth/data/api_auth_service.dart';

class _RecordingAnalytics implements AnalyticsService {
  final calls = <String>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      calls.add('track:$event');

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() => calls.add('reset');

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

  late _RecordingAnalytics analytics;
  late ApiAuthService auth;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'arul_access_token': 'acc',
      'arul_refresh_token': 'ref',
    });
    analytics = _RecordingAnalytics();
    auth = ApiAuthService(
      apiClient: ApiClient(
        httpClient: MockClient((req) async {
          if (req.url.path == '/me' && req.method == 'GET') {
            return _json({
              'user': {'id': 'u1', 'displayName': 'A', 'email': 'a@x'},
            }, 200);
          }
          return _json({'ok': true}, 200);
        }),
      ),
      analytics: analytics,
      crash: const NoOpCrashReporter(),
      freshInstall: false,
    );
    await auth.initialized;
    expect(auth.currentState.isAuthenticated, isTrue);
  });

  test(
    'sign-out resets analytics once, before the signed-out state is emitted',
    () async {
      int? resetsWhenSignedOut;
      final sub = auth.authStateChanges.listen((s) {
        if (!s.isAuthenticated) {
          resetsWhenSignedOut = analytics.calls
              .where((c) => c == 'reset')
              .length;
        }
      });

      await auth.signOut();
      await Future<void>.delayed(Duration.zero);

      expect(analytics.calls.where((c) => c == 'reset'), hasLength(1));
      expect(resetsWhenSignedOut, 1);
      await sub.cancel();
    },
  );

  test('account deletion reports account_deleted first, then resets', () async {
    await auth.deleteAccount();

    expect(
      analytics.calls,
      containsAllInOrder(['track:account_deleted', 'reset']),
    );
    expect(auth.currentState.isAuthenticated, isFalse);
  });
}
