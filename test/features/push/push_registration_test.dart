import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/config/build_info.dart';
import 'package:arul/core/crash/crash_reporter.dart';
import 'package:arul/features/push/data/push_permission.dart';
import 'package:arul/features/push/data/push_registration.dart';

/// Two contracts, both about restraint.
///
/// Registration must post ONCE per launch however many triggers fire (a `/me` landing, a sign-in
/// completing and a locale settling all call it), and a Firebase failure must never reach the user —
/// a phone without Google Play services throws at `getId()` and simply stays unreachable.
///
/// The prompt must be spent once per install whatever the OS answered: Android stops showing the
/// dialog after two refusals, so a third ask would read back to us as a fresh refusal.
void main() {
  setUp(() {
    // The registration probes Build.VERSION.SDK_INT over a platform channel; without a binding the
    // messenger itself throws, and the class is deliberately deaf to that (a diagnostic column must
    // never cost the row). Bring the binding up so these tests exercise the real path.
    TestWidgetsFlutterBinding.ensureInitialized();
    AndroidVersion.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  group('PushRegistration', () {
    test('posts once per launch however many triggers fire', () async {
      final api = _RecordingApi();
      final registration = _make(api);

      await registration.register(account: 'user-a');
      await registration.register(account: 'user-a');
      await registration.register(account: 'user-a');

      expect(api.posts, hasLength(1));
      expect(api.posts.single.path, '/me/device');
      expect(api.posts.single.requiresAuth, isTrue);
      expect(api.posts.single.body?['fid'], 'fid-test');
      expect(api.posts.single.body?['lang'], 'ta');
      expect(api.posts.single.body?['appBuild'], 76);
    });

    test(
      'a signed-out phone registers through /push/device, unauthenticated, with the same body',
      () async {
        final api = _RecordingApi();
        final registration = _make(api);

        await registration.register();
        await registration.register();

        expect(api.posts, hasLength(1));
        expect(api.posts.single.path, '/push/device');
        expect(api.posts.single.requiresAuth, isFalse);
        expect(api.posts.single.body, {
          'fid': 'fid-test',
          'token': 'tok-test',
          'lang': 'ta',
          'appBuild': 76,
        });
      },
    );

    test(
      'signing in after a signed-out registration re-posts through /me/device',
      () async {
        final api = _RecordingApi();
        final registration = _make(api);

        await registration.register();
        await registration.register(account: 'user-a');

        expect(api.posts.map((p) => p.path), ['/push/device', '/me/device']);
      },
    );

    test(
      'a sign-in landing while the signed-out post is in flight is not swallowed by it',
      () async {
        final gate = Completer<void>();
        final api = _RecordingApi(gate: gate.future);
        final registration = _make(api);

        final signedOut = registration.register();
        final signedIn = registration.register(account: 'user-a');
        gate.complete();
        await Future.wait([signedOut, signedIn]);

        expect(api.posts.map((p) => p.path), ['/push/device', '/me/device']);
      },
    );

    test('a token refresh posts to the route of the current state', () async {
      final api = _RecordingApi();
      final refresh = StreamController<String>.broadcast();
      addTearDown(refresh.close);
      final registration = _make(api, tokenRefresh: refresh.stream);

      await registration.register();
      registration.listenForTokenRefresh();
      refresh.add('t1');
      await Future<void>.delayed(Duration.zero);
      expect(api.posts.last.path, '/push/device');

      await registration.register(account: 'user-a');
      refresh.add('t2');
      await Future<void>.delayed(Duration.zero);
      expect(api.posts.last.path, '/me/device');
      registration.dispose();
    });

    test(
      'a language change re-posts the row — that is what keeps "By language" honest',
      () async {
        final api = _RecordingApi();
        var lang = 'ta';
        final registration = _make(api, language: () => lang);

        await registration.register();
        lang = 'hi';
        await registration.register();

        expect(api.posts, hasLength(2));
        expect(api.posts.last.body?['lang'], 'hi');
      },
    );

    test(
      'a different account in the same process re-posts — the row must change hands',
      () async {
        final api = _RecordingApi();
        final registration = _make(api);

        await registration.register(account: 'user-a');
        await registration.register(account: 'user-a');
        // Sign-out, sign-in as someone else: fid, token and language are identical.
        await registration.register(account: 'user-b');

        expect(api.posts, hasLength(2));
      },
    );

    test('force re-posts an identical body — the token-refresh path', () async {
      final api = _RecordingApi();
      final registration = _make(api);
      await registration.register();
      await registration.register(force: true);
      expect(api.posts, hasLength(2));
    });

    test('a token refresh re-posts on its own', () async {
      final api = _RecordingApi();
      final refresh = StreamController<String>.broadcast();
      addTearDown(refresh.close);
      final registration = _make(api, tokenRefresh: refresh.stream);
      await registration.register();
      expect(api.posts, hasLength(1));

      registration.listenForTokenRefresh();
      refresh.add('new-token');
      await Future<void>.delayed(Duration.zero);

      expect(api.posts, hasLength(2));
      registration.dispose();
    });

    test(
      'a phone with no Play services: no throw, no post, app unaffected',
      () async {
        final api = _RecordingApi();
        final crash = _RecordingCrash();
        final registration = PushRegistration(
          apiClient: api,
          crash: crash,
          appLanguage: () => 'en',
          fid: () => throw StateError('no Google Play services'),
          appBuild: () async => 76,
        );

        await expectLater(registration.register(), completes);
        expect(api.posts, isEmpty);
        // Silent to the user, loud to Crashlytics — that is how the first week of field data shows
        // which phones never register.
        expect(crash.errors, isNotEmpty);
      },
    );

    test('an empty fid registers nothing rather than an empty row', () async {
      final api = _RecordingApi();
      final registration = _make(api, fid: () async => '');
      await registration.register();
      expect(api.posts, isEmpty);
    });

    test(
      'a phone that yields no token still registers — the fid is its identity',
      () async {
        final api = _RecordingApi();
        final registration = _make(api, token: () async => null);
        await registration.register();
        expect(api.posts, hasLength(1));
        expect(api.posts.single.body!.containsKey('token'), isFalse);
      },
    );
  });

  group('PushPermission', () {
    test('asks once, records the grant, and never asks again', () async {
      final prefs = await SharedPreferences.getInstance();
      final analytics = _RecordingAnalytics();
      var asks = 0;
      final permission = PushPermission(
        prefs: prefs,
        analytics: analytics,
        crash: const NoOpCrashReporter(),
        request: () async {
          asks += 1;
          return AuthorizationStatus.authorized;
        },
      );

      expect(permission.alreadyPrompted, isFalse);
      expect(await permission.promptOnce(), isTrue);
      expect(permission.alreadyPrompted, isTrue);
      expect(analytics.events, ['push_permission']);

      expect(await permission.promptOnce(), isFalse);
      expect(
        asks,
        1,
        reason: 'Android stops showing its dialog after two refusals',
      );
    });

    test('a DENIED answer is final for this install', () async {
      final prefs = await SharedPreferences.getInstance();
      final permission = PushPermission(
        prefs: prefs,
        analytics: _RecordingAnalytics(),
        crash: const NoOpCrashReporter(),
        request: () async => AuthorizationStatus.denied,
      );
      expect(await permission.promptOnce(), isFalse);
      expect(permission.alreadyPrompted, isTrue);
    });

    test(
      'a prompt spent on a previous launch is not repeated, and fires nothing',
      () async {
        SharedPreferences.setMockInitialValues({'arul_push_prompted': true});
        final prefs = await SharedPreferences.getInstance();
        final analytics = _RecordingAnalytics();
        var asks = 0;
        final permission = PushPermission(
          prefs: prefs,
          analytics: analytics,
          crash: const NoOpCrashReporter(),
          request: () async {
            asks += 1;
            return AuthorizationStatus.authorized;
          },
        );

        expect(permission.alreadyPrompted, isTrue);
        expect(await permission.promptOnce(), isFalse);
        expect(asks, 0);
        expect(analytics.events, isEmpty);
      },
    );

    test('a phone that throws at the ask still spends the question', () async {
      final prefs = await SharedPreferences.getInstance();
      final crash = _RecordingCrash();
      final permission = PushPermission(
        prefs: prefs,
        analytics: _RecordingAnalytics(),
        crash: crash,
        request: () => throw StateError('no Google Play services'),
      );
      expect(await permission.promptOnce(), isFalse);
      // Asking again every launch would be a dialog-less no-op on this phone and a nuisance on any
      // phone the throw turns out to be transient on.
      expect(permission.alreadyPrompted, isTrue);
      expect(crash.errors, isNotEmpty);
    });
  });
}

PushRegistration _make(
  ApiClient api, {
  String Function()? language,
  Future<String?> Function()? fid,
  Future<String?> Function()? token,
  Stream<String>? tokenRefresh,
}) => PushRegistration(
  apiClient: api,
  crash: const NoOpCrashReporter(),
  appLanguage: language ?? () => 'ta',
  fid: fid ?? () async => 'fid-test',
  token: token ?? () async => 'tok-test',
  tokenRefresh: tokenRefresh,
  appBuild: () async => 76,
);

class _RecordedPost {
  _RecordedPost(this.path, this.body, this.requiresAuth);
  final String path;
  final Map<String, dynamic>? body;
  final bool requiresAuth;
}

class _RecordingApi extends ApiClient {
  _RecordingApi({this.gate});

  /// Holds every post open until it completes, to put two registrations in flight at once.
  final Future<void>? gate;
  final List<_RecordedPost> posts = [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requiresAuth = true,
  }) async {
    posts.add(_RecordedPost(path, body, requiresAuth));
    await gate;
    return {'ok': true};
  }
}

class _RecordingCrash implements CrashReporter {
  final List<Object> errors = [];

  @override
  void recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
  }) => errors.add(error);

  @override
  void setUserId(String? id) {}

  @override
  void log(String message) {}

  @override
  void setCustomKey(String key, Object value) {}
}

class _RecordingAnalytics implements AnalyticsService {
  final List<String> events = [];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add(event);

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}
