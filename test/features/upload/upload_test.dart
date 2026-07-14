// Tests for the upload feature:
//   - UploadConstraints: size/type limits and labels (the client+server contract)
//   - UploadNotifier: the branches reachable without the real R2 PUT
//     (the actual file PUT uses a top-level http.put that isn't injectable):
//       * not signed in        → UploadError('Not signed in')
//       * Worker omits uploadUrl→ UploadError('Upload URL not received')
//       * Worker rejects (e.g. too_large) → UploadError(server message)

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:arul/core/api/api_client.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/upload/providers/upload_provider.dart';

// ─── UploadConstraints (pure) ─────────────────────────────────────────────────

void main() {
  group('UploadConstraints (wallpaper-only in Arul)', () {
    test('maxBytes by wallpaper type', () {
      expect(UploadConstraints.maxBytes('static'), 10 * 1024 * 1024);
      expect(UploadConstraints.maxBytes('live'), 50 * 1024 * 1024);
    });

    test('allowedTypes by wallpaper type', () {
      expect(UploadConstraints.allowedTypes('static'), {
        'image/jpeg',
        'image/png',
        'image/webp',
      });
      expect(UploadConstraints.allowedTypes('live'), {'video/mp4'});
    });

    test('maxLabel renders the megabyte ceiling', () {
      expect(UploadConstraints.maxLabel('static'), '10MB');
      expect(UploadConstraints.maxLabel('live'), '50MB');
    });

    test('typeLabel describes the accepted formats', () {
      expect(UploadConstraints.typeLabel('static'), contains('image'));
      expect(UploadConstraints.typeLabel('live'), contains('MP4'));
    });

    test('mimeFromName maps wallpaper extensions (incl. mp4)', () {
      expect(UploadConstraints.mimeFromName('a.jpg'), 'image/jpeg');
      expect(UploadConstraints.mimeFromName('a.PNG'), 'image/png');
      expect(UploadConstraints.mimeFromName('a.mp4'), 'video/mp4');
      expect(
        UploadConstraints.mimeFromName('a.exe'),
        'application/octet-stream',
      );
    });
  });

  // ─── UploadNotifier (reachable branches) ─────────────────────────────────────

  group('UploadNotifier.submit', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    Future<ProviderContainer> container({
      required AuthUserState auth,
      required MockClient mock,
    }) async {
      final api = ApiClient(httpClient: mock);
      await api.setTokens(accessToken: 'acc', refreshToken: 'ref');
      final c = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authServiceProvider.overrideWithValue(_FakeAuth(auth)),
        ],
      );
      // Subscribe + pump so the auth stream emits and asData is populated
      // before submit reads ref.read(authStateStreamProvider).asData.
      c.listen(authStateStreamProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      return c;
    }

    Future<void> submit(ProviderContainer c) => c
        .read(uploadProvider.notifier)
        .submit(
          kind: 'wallpaper',
          filePath: '/does/not/matter',
          fileName: 'pic.jpg',
          mimeType: 'image/jpeg',
          fileSize: 1234,
        );

    test('not signed in → UploadError before any network call', () async {
      var calls = 0;
      final c = await container(
        auth: AuthUserState.unauthenticated(),
        mock: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(c.dispose);

      await submit(c);
      final s = c.read(uploadProvider);
      expect(s, isA<UploadError>());
      expect((s as UploadError).message, 'Not signed in');
      expect(calls, 0);
    });

    test('Worker response without uploadUrl → UploadError', () async {
      final c = await container(
        auth: AuthUserState.authenticated(userId: 'u1'),
        mock: MockClient((req) async {
          expect(req.url.path, '/media/upload-url');
          return http.Response(
            jsonEncode({'publicUrl': 'x'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(c.dispose);

      await submit(c);
      final s = c.read(uploadProvider);
      expect(s, isA<UploadError>());
      expect((s as UploadError).message, 'Upload URL not received');
    });

    test(
      'Worker rejection (too_large) surfaces as UploadError(message)',
      () async {
        final c = await container(
          auth: AuthUserState.authenticated(userId: 'u1'),
          mock: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {'code': 'too_large', 'message': 'File too large'},
              }),
              400,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(c.dispose);

        await submit(c);
        final s = c.read(uploadProvider);
        expect(s, isA<UploadError>());
        expect((s as UploadError).message, 'File too large');
      },
    );

    test(
      'upload-url request scopes the key to user/<id>/submissions/',
      () async {
        String? sentKey;
        final c = await container(
          auth: AuthUserState.authenticated(userId: 'u1'),
          mock: MockClient((req) async {
            sentKey =
                (jsonDecode(req.body) as Map<String, dynamic>)['key']
                    as String?;
            // Return no uploadUrl to stop before the (un-mockable) R2 PUT.
            return http.Response(
              '{}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(c.dispose);

        await submit(c);
        expect(sentKey, startsWith('user/u1/submissions/'));
        expect(sentKey, endsWith('_pic.jpg'));
      },
    );
  });
}

// Emits the given auth state once then closes (clean StreamProvider dispose).
class _FakeAuth implements AuthService {
  _FakeAuth(this._state);
  final AuthUserState _state;

  @override
  Stream<AuthUserState> get authStateChanges => Stream.value(_state);

  @override
  AuthUserState get currentState => _state;

  @override
  Future<void> get initialized => Future.value();

  @override
  Future<AuthResult> signInWith(AuthProvider provider) =>
      throw UnimplementedError();

  @override
  Future<void> updateDisplayName(String name) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}
