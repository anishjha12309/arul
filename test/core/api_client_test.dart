// ApiClient is the single HTTP entry point to the Worker API -> this pins what every gated call depends on.
// Covered: typed ApiException flags, token persistence, JSON success/error parsing, the Authorization header.
// Also the single-flight 401 -> /auth/refresh -> retry-once path.
// http is mocked with package:http/testing MockClient.
// Secure storage uses the in-memory platform FlutterSecureStorage.setMockInitialValues installs.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/error/app_exception.dart';

// Runs [body] and returns what it threw — and FAILS if anything else escaped to the zone.
// The single-flight completer is awaited only when a SECOND concurrent caller joins it. Its error
// used to be left unlistened on a lone failing refresh -> an UNCAUGHT zone error on top of the one
// the caller caught, which Crashlytics logged FATAL for every dead session. The zone is the witness.
Future<Object?> _captureThrow(Future<void> Function() body) async {
  Object? thrown;
  final leaked = <Object>[];
  await runZonedGuarded(() async {
    try {
      await body();
    } catch (e) {
      thrown = e;
    }
  }, (e, _) => leaked.add(e));
  // An unlistened error completion is reported a microtask or two later.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(leaked, isEmpty, reason: 'nothing but the thrown error may escape');
  return thrown;
}

// The session store on a phone whose Android Keystore refuses it — the field's exact shape:
// the plugin's PlatformException carries the Java stack, rooted in android.security.keystore.
class _KeystoreStorage extends FlutterSecureStorage {
  _KeystoreStorage({this.refuse = true});

  static const message = 'Failed to generate key pair';

  bool refuse;
  int calls = 0;
  final Map<String, String> _values = {};

  Never _throw() => throw PlatformException(
    code: 'Exception encountered',
    message: message,
    details:
        'java.security.ProviderException: $message\n\tat android.security.keystore.'
        'AndroidKeyStoreKeyPairGeneratorSpi.generateKeystoreKeyPair\nCaused by: '
        'android.security.KeyStoreException: Memory allocation failed',
  );

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls++;
    if (refuse) _throw();
    return _values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls++;
    if (refuse) _throw();
    if (value != null) _values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls++;
    if (refuse) _throw();
    _values.remove(key);
  }
}

// Builds a JSON http.Response with the content-type ApiClient expects.
http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  ApiClient makeClient(MockClient mock) => ApiClient(httpClient: mock);

  // ─── ApiException flags ──────────────────────────────────────────────────

  group('ApiException', () {
    test('isPremiumRequired only for 403 + premium_required code', () {
      const e = ApiException(
        code: 'premium_required',
        message: 'x',
        status: 403,
      );
      expect(e.isPremiumRequired, isTrue);

      const wrongCode = ApiException(
        code: 'forbidden',
        message: 'x',
        status: 403,
      );
      expect(wrongCode.isPremiumRequired, isFalse);

      const wrongStatus = ApiException(
        code: 'premium_required',
        message: 'x',
        status: 401,
      );
      expect(wrongStatus.isPremiumRequired, isFalse);
    });

    test('isUnauthorized is true only for 401', () {
      expect(
        const ApiException(
          code: 'unauthorized',
          message: 'x',
          status: 401,
        ).isUnauthorized,
        isTrue,
      );
      expect(
        const ApiException(code: 'x', message: 'x', status: 403).isUnauthorized,
        isFalse,
      );
    });
  });

  test(
    'isSessionExpired covers every no-session code, never a transient one',
    () {
      ApiException e(String code) =>
          ApiException(code: code, message: 'x', status: 401);
      expect(e('no_refresh_token').isSessionExpired, isTrue);
      expect(e('invalid_refresh').isSessionExpired, isTrue);
      expect(e('invalid_refresh_response').isSessionExpired, isTrue);
      expect(e('refresh_unavailable').isSessionExpired, isFalse);
      expect(e('unauthorized').isSessionExpired, isFalse);
    },
  );

  // ─── A Keystore that refuses the session (Android 8.1/9, keymaster -41) ───────────────────

  group('keystore refusal', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    ApiClient client(_KeystoreStorage storage, {List<Object>? reported}) =>
        ApiClient(
          storage: storage,
          httpClient: MockClient((_) async => _json({}, 200)),
          plainStore: prefs,
          onKeystoreRefused: (e, _) => reported?.add(e),
        );

    test('the session lands in app-private storage and reads back', () async {
      final reported = <Object>[];
      final c = client(_KeystoreStorage(), reported: reported);

      await c.setTokens(accessToken: 'acc-1', refreshToken: 'ref-1');

      expect(await c.readAccessToken(), 'acc-1');
      expect(await c.readRefreshToken(), 'ref-1');
      expect(await c.hasTokens(), isTrue);
      expect(reported, hasLength(1), reason: 'one non-fatal per process');
    });

    test(
      'the switch is sticky: a later process never asks the Keystore again',
      () async {
        await client(
          _KeystoreStorage(),
        ).setTokens(accessToken: 'acc-1', refreshToken: 'ref-1');

        // Even a Keystore that works again must not split the session across two stores.
        final healthyNow = _KeystoreStorage(refuse: false);
        final next = client(healthyNow);
        expect(await next.readAccessToken(), 'acc-1');
        expect(healthyNow.calls, 0);
      },
    );

    test('sign-out clears the app-private copy', () async {
      final c = client(_KeystoreStorage());
      await c.setTokens(accessToken: 'acc-1', refreshToken: 'ref-1');
      await c.cacheProfile(userId: 'u1', displayName: 'A');

      await c.clearTokens();

      expect(await c.hasTokens(), isFalse);
      expect(await c.readRefreshToken(), isNull);
      expect(await c.readCachedProfile(), isNull);
    });

    test(
      'a failure that is NOT the Keystore propagates and switches nothing',
      () async {
        final c = ApiClient(
          storage: _NotKeystoreStorage(),
          httpClient: MockClient((_) async => _json({}, 200)),
          plainStore: prefs,
        );
        await expectLater(
          c.readAccessToken(),
          throwsA(isA<PlatformException>()),
        );
        expect(prefs.getBool('arul_keystore_refused'), isNull);
      },
    );

    test(
      'with no app-private store (tests, define-less runs) the refusal propagates',
      () async {
        final c = ApiClient(
          storage: _KeystoreStorage(),
          httpClient: MockClient((_) async => _json({}, 200)),
        );
        await expectLater(c.hasTokens(), throwsA(isA<PlatformException>()));
      },
    );

    test('both field messages are recognised as Keystore refusals', () {
      for (final message in [
        'Failed to generate key pair',
        'Failed to obtain information about private key',
      ]) {
        expect(
          ApiClient.isKeystoreRefusal(
            PlatformException(
              code: 'Exception encountered',
              message: message,
              details: 'at android.security.keystore.AndroidKeyStoreProvider',
            ),
          ),
          isTrue,
        );
      }
      expect(
        ApiClient.isKeystoreRefusal(
          PlatformException(
            code: 'Exception encountered',
            message: 'disk full',
          ),
        ),
        isFalse,
      );
    });
  });

  // ─── Token persistence ───────────────────────────────────────────────────

  group('token storage', () {
    test('setTokens persists and reads back access + refresh tokens', () async {
      final c = makeClient(MockClient((_) async => _json({}, 200)));
      await c.setTokens(accessToken: 'acc-1', refreshToken: 'ref-1');

      expect(await c.readAccessToken(), 'acc-1');
      expect(await c.readRefreshToken(), 'ref-1');
      expect(await c.hasTokens(), isTrue);
    });

    test('clearTokens removes both and hasTokens becomes false', () async {
      final c = makeClient(MockClient((_) async => _json({}, 200)));
      await c.setTokens(accessToken: 'acc-1', refreshToken: 'ref-1');

      await c.clearTokens();
      expect(await c.readAccessToken(), isNull);
      expect(await c.readRefreshToken(), isNull);
      expect(await c.hasTokens(), isFalse);
    });

    test('hasTokens is false on a fresh client', () async {
      final c = makeClient(MockClient((_) async => _json({}, 200)));
      expect(await c.hasTokens(), isFalse);
    });
  });

  // ─── Request / response basics ─────────────────────────────────────────────

  group('request & response parsing', () {
    test('GET returns the decoded JSON body on 200', () async {
      final c = makeClient(
        MockClient((req) async => _json({'user': 'aisha'}, 200)),
      );
      final data = await c.get('/me', requiresAuth: false);
      expect(data['user'], 'aisha');
    });

    test('POST sends a JSON body and the bearer token header', () async {
      http.Request? captured;
      final c = makeClient(
        MockClient((req) async {
          captured = req;
          return _json({'ok': true}, 200);
        }),
      );
      await c.setTokens(accessToken: 'acc-9', refreshToken: 'ref-9');

      await c.post(
        '/media/signed-url',
        body: {'id': 'w1', 'kind': 'wallpaper'},
      );

      expect(captured!.method, 'POST');
      expect(captured!.headers['Authorization'], 'Bearer acc-9');
      expect(captured!.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(captured!.body), {'id': 'w1', 'kind': 'wallpaper'});
    });

    test('no Authorization header is sent when there is no token', () async {
      http.Request? captured;
      final c = makeClient(
        MockClient((req) async {
          captured = req;
          return _json({}, 200);
        }),
      );
      await c.get('/me', requiresAuth: false);
      expect(captured!.headers.containsKey('Authorization'), isFalse);
    });

    test(
      'non-2xx throws ApiException with code/message/status from envelope',
      () async {
        final c = makeClient(
          MockClient(
            (_) async => _json({
              'error': {'code': 'invalid_kind', 'message': 'bad kind'},
            }, 400),
          ),
        );

        expect(
          () => c.post('/media/signed-url', requiresAuth: false),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', 400)
                .having((e) => e.code, 'code', 'invalid_kind')
                .having((e) => e.message, 'message', 'bad kind'),
          ),
        );
      },
    );

    test('unparseable body throws ApiException(parse_error)', () async {
      final c = makeClient(
        MockClient(
          (_) async => http.Response(
            '<html>oops',
            502,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      expect(
        () => c.get('/me', requiresAuth: false),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'parse_error'),
        ),
      );
    });
  });

  // ─── 401 refresh / retry ───────────────────────────────────────────────────

  group('401 → refresh → retry', () {
    test('refreshes once on 401, then retries the original request', () async {
      var refreshCalls = 0;
      var protectedCalls = 0;
      final c = makeClient(
        MockClient((req) async {
          if (req.url.path == '/auth/refresh') {
            refreshCalls++;
            return _json({
              'accessToken': 'acc-new',
              'refreshToken': 'ref-new',
            }, 200);
          }
          protectedCalls++;
          // Old token -> 401; the new token after refresh -> 200.
          final auth = req.headers['Authorization'];
          return auth == 'Bearer acc-new'
              ? _json({'ok': true}, 200)
              : _json({
                  'error': {'code': 'unauthorized', 'message': 'expired'},
                }, 401);
        }),
      );
      await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');

      final data = await c.get('/me');

      expect(data['ok'], true);
      expect(refreshCalls, 1);
      expect(protectedCalls, 2, reason: 'original 401 + one retry');
      expect(await c.readAccessToken(), 'acc-new');
    });

    test('concurrent 401s trigger only ONE refresh (single-flight)', () async {
      var refreshCalls = 0;
      final c = makeClient(
        MockClient((req) async {
          if (req.url.path == '/auth/refresh') {
            refreshCalls++;
            return _json({
              'accessToken': 'acc-new',
              'refreshToken': 'ref-new',
            }, 200);
          }
          final auth = req.headers['Authorization'];
          return auth == 'Bearer acc-new'
              ? _json({'ok': true}, 200)
              : _json({
                  'error': {'code': 'unauthorized', 'message': 'expired'},
                }, 401);
        }),
      );
      await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');

      await Future.wait([c.get('/a'), c.get('/b'), c.get('/c')]);

      expect(refreshCalls, 1, reason: 'single-flight collapses the refreshes');
    });

    const captureThrow = _captureThrow;

    test('refresh failure clears tokens and throws', () async {
      final c = makeClient(
        MockClient((req) async {
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
      await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');

      final thrown = await captureThrow(() => c.get('/me'));
      expect(thrown, isA<ApiException>());
      expect(
        await c.hasTokens(),
        isFalse,
        reason: 'tokens cleared on failed refresh',
      );
    });

    test(
      '401 with no refresh token clears and throws no_refresh_token',
      () async {
        final c = makeClient(
          MockClient(
            (_) async => _json({
              'error': {'code': 'unauthorized', 'message': 'x'},
            }, 401),
          ),
        );
        await c.setTokens(accessToken: 'acc-old', refreshToken: '');

        final thrown = await captureThrow(() => c.get('/me'));
        expect(
          thrown,
          isA<ApiException>().having((e) => e.code, 'code', 'no_refresh_token'),
        );
      },
    );

    test(
      'requiresAuth:false does NOT refresh on 401 — throws directly',
      () async {
        var refreshCalls = 0;
        final c = makeClient(
          MockClient((req) async {
            if (req.url.path == '/auth/refresh') refreshCalls++;
            return _json({
              'error': {'code': 'unauthorized', 'message': 'x'},
            }, 401);
          }),
        );
        await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');

        await expectLater(
          c.get('/public', requiresAuth: false),
          throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
        );
        expect(refreshCalls, 0);
      },
    );

    test(
      'a dead refresh token ends the session: sessionEnded fires once',
      () async {
        final c = makeClient(
          MockClient((req) async {
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
        await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');
        var ended = 0;
        final sub = c.sessionEnded.listen((_) => ended++);

        final thrown = await captureThrow(() => c.get('/me'));

        expect(
          thrown,
          isA<ApiException>().having(
            (e) => e.isSessionExpired,
            'expired',
            true,
          ),
        );
        expect(ended, 1);
        await sub.cancel();
      },
    );

    test(
      'a TRANSIENT refresh failure keeps the session and never ends it',
      () async {
        final c = makeClient(
          MockClient((req) async {
            if (req.url.path == '/auth/refresh') {
              return _json({
                'error': {'code': 'unavailable', 'message': 'blip'},
              }, 503);
            }
            return _json({
              'error': {'code': 'unauthorized', 'message': 'x'},
            }, 401);
          }),
        );
        await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');
        var ended = 0;
        final sub = c.sessionEnded.listen((_) => ended++);

        final thrown = await captureThrow(() => c.get('/me'));

        expect(
          thrown,
          isA<ApiException>()
              .having((e) => e.code, 'code', 'refresh_unavailable')
              .having((e) => e.isSessionExpired, 'expired', false),
        );
        expect(ended, 0);
        expect(
          await c.hasTokens(),
          isTrue,
          reason: 'a blip never signs a payer out',
        );
        await sub.cancel();
      },
    );
  });

  // ─── Request timeout (offline mid-call backstop) ────────────────────────────

  group('request timeout', () {
    const captureThrow = _captureThrow;

    test(
      'a hung request throws a network-typed error instead of hanging',
      () async {
        // The exact offline-mid-call case -> the socket never responds -> without the bounded timeout the caller spins.
        final c = ApiClient(
          httpClient: MockClient((_) => Completer<http.Response>().future),
          requestTimeout: const Duration(milliseconds: 50),
        );

        Object? thrown;
        try {
          await c.get('/me/subscription', requiresAuth: false);
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<http.ClientException>());
        expect(
          isNetworkError(thrown!),
          isTrue,
          reason:
              'a timeout must classify as connectivity-class so apply/share '
              'shows the offline message rather than hanging',
        );
      },
    );

    test(
      'the /auth/refresh POST also times out (retry path never hangs)',
      () async {
        // GET -> 401 forces a refresh; the /auth/refresh POST then hangs.
        final c = ApiClient(
          httpClient: MockClient((req) {
            if (req.url.path == '/auth/refresh') {
              return Completer<http.Response>().future; // never responds
            }
            return Future.value(
              _json({
                'error': {'code': 'unauthorized', 'message': 'x'},
              }, 401),
            );
          }),
          requestTimeout: const Duration(milliseconds: 50),
        );
        await c.setTokens(accessToken: 'acc-old', refreshToken: 'ref-old');

        final thrown = await captureThrow(() => c.get('/me/subscription'));
        expect(thrown, isA<http.ClientException>());
        expect(isNetworkError(thrown!), isTrue);
      },
    );
  });
}

class _NotKeystoreStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw PlatformException(
    code: 'Exception encountered',
    message: 'Failed to commit encrypted data to disk',
    details: 'java.lang.Exception: storage may be full',
  );
}
