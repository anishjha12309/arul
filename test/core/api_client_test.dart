// Tests for ApiClient — the single HTTP entry point to the Worker API.
// Covers: typed ApiException flags, token persistence (flutter_secure_storage),
// JSON success/error parsing, Authorization header attachment, and the
// single-flight 401 → /auth/refresh → retry-once logic that every gated call
// depends on.
//
// http is mocked with package:http/testing MockClient; secure storage uses the
// in-memory test platform installed by FlutterSecureStorage.setMockInitialValues.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/error/app_exception.dart';

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
          // Old token → 401; new token (after refresh) → 200.
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

    // The single-flight completer is only awaited when a *second* concurrent
    // caller is waiting on it; a lone failing refresh therefore leaves a phantom
    // unhandled error on completer.future in addition to the error it throws to
    // the caller. We assert the thrown error here and absorb the phantom in a
    // guarded zone (source is owned by another agent; not ours to change).
    Future<Object?> captureThrow(Future<void> Function() body) async {
      Object? thrown;
      await runZonedGuarded(
        () async {
          try {
            await body();
          } catch (e) {
            thrown = e;
          }
        },
        (_, _) {
          /* absorb phantom unhandled completer error */
        },
      );
      return thrown;
    }

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
  });

  // ─── Request timeout (offline mid-call backstop) ────────────────────────────

  group('request timeout', () {
    // Absorbs the phantom unhandled error a lone failing refresh leaves on the
    // single-flight completer.future (same reason the 401 group needs it).
    Future<Object?> captureThrow(Future<void> Function() body) async {
      Object? thrown;
      await runZonedGuarded(
        () async {
          try {
            await body();
          } catch (e) {
            thrown = e;
          }
        },
        (_, _) {
          /* absorb phantom unhandled completer error */
        },
      );
      return thrown;
    }

    test(
      'a hung request throws a network-typed error instead of hanging',
      () async {
        // The exact offline-mid-call case: the socket never responds. Without the
        // bounded timeout this future never completes and the caller spins forever.
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
        // GET → 401 forces a refresh; the /auth/refresh POST then hangs.
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
