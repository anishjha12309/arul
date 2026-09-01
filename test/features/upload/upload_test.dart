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
  group('UploadConstraints (wallpaper + ringtone)', () {
    test('maxBytes by kind and wallpaper type', () {
      expect(
        UploadConstraints.maxBytes('wallpaper', 'static'),
        10 * 1024 * 1024,
      );
      expect(UploadConstraints.maxBytes('wallpaper', 'live'), 50 * 1024 * 1024);
      // wallpaperType is ignored for a ringtone — the audio cap either way.
      expect(
        UploadConstraints.maxBytes('ringtone', 'static'),
        15 * 1024 * 1024,
      );
      expect(UploadConstraints.maxBytes('ringtone', 'live'), 15 * 1024 * 1024);
    });

    test('allowedTypes by kind and wallpaper type', () {
      expect(UploadConstraints.allowedTypes('wallpaper', 'static'), {
        'image/jpeg',
        'image/png',
        'image/webp',
      });
      expect(UploadConstraints.allowedTypes('wallpaper', 'live'), {
        'video/mp4',
      });
      expect(UploadConstraints.allowedTypes('ringtone', 'static'), {
        'audio/mpeg',
        'audio/aac',
        'audio/mp4',
        'audio/x-m4a',
      });
    });

    test('a ringtone never accepts image or video types', () {
      final audio = UploadConstraints.allowedTypes('ringtone', 'static');
      expect(audio.contains('video/mp4'), isFalse);
      expect(audio.contains('image/jpeg'), isFalse);
    });

    test('maxLabel renders the megabyte ceiling', () {
      expect(UploadConstraints.maxLabel('wallpaper', 'static'), '10MB');
      expect(UploadConstraints.maxLabel('wallpaper', 'live'), '50MB');
      expect(UploadConstraints.maxLabel('ringtone', 'static'), '15MB');
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

    test('mimeFromName maps the audio extensions the server allow-lists', () {
      expect(UploadConstraints.mimeFromName('a.mp3'), 'audio/mpeg');
      expect(UploadConstraints.mimeFromName('a.AAC'), 'audio/aac');
      expect(UploadConstraints.mimeFromName('a.m4a'), 'audio/mp4');
    });

    test(
      'unsupported audio resolves to a type the ringtone allow-list rejects',
      () {
        // ogg/wav/flac are named so the user gets the authored "choose an
        // MP3/AAC/M4A" toast rather than the generic octet-stream path — but they
        // must still FAIL the allow-list, not sneak through it.
        final audio = UploadConstraints.allowedTypes('ringtone', 'static');
        for (final name in ['a.ogg', 'a.wav', 'a.flac']) {
          expect(audio.contains(UploadConstraints.mimeFromName(name)), isFalse);
        }
      },
    );
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

    test(
      'a ringtone submit sends kind=ringtone with the audio content-type',
      () async {
        Map<String, dynamic>? sent;
        final c = await container(
          auth: AuthUserState.authenticated(userId: 'u1'),
          mock: MockClient((req) async {
            sent = jsonDecode(req.body) as Map<String, dynamic>;
            // No uploadUrl → stop before the (un-mockable) R2 PUT.
            return http.Response(
              '{}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(c.dispose);

        await c
            .read(uploadProvider.notifier)
            .submit(
              kind: 'ringtone',
              filePath: '/does/not/matter',
              fileName: 'kavasam.mp3',
              mimeType: 'audio/mpeg',
              fileSize: 4321,
              category: 'murugan',
            );

        // The presign request is what carries the kind — the Worker sizes the
        // allow-list off contentType and QCs the object against `kind` at confirm.
        expect(sent?['kind'], 'ringtone');
        expect(sent?['contentType'], 'audio/mpeg');
        expect(sent?['key'], startsWith('user/u1/submissions/'));
        expect(sent?['key'], endsWith('_kavasam.mp3'));
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
  Future<AuthResult> signInWith(AuthProvider provider, {bool auto = false}) =>
      throw UnimplementedError();

  @override
  void abandonPendingSignIn() {}

  @override
  Future<void> updateDisplayName(String name) async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}
