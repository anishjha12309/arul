// The wall's live clip, every deity's fetched by the poster's wallpaper id: only after the wall is
// up AND Google's surface has shown, and never on a poster-rule phone, a signed-in session, Data
// Saver, under the kill switch or after a failed transfer — every one of those keeps the poster.

import 'package:arul/core/config/build_info.dart';
import 'package:arul/core/connectivity/data_saver.dart';
import 'package:arul/core/experiments/experiments.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/domain/regional_art.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/auth/providers/launch_clip_provider.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_prefetch_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePrefetch extends WallpaperPrefetchService {
  _FakePrefetch() : super(cdnBaseUrl: 'https://cdn.test');

  final asked = <String>[];
  String? answer = '/cache/clip.mp4';

  @override
  Future<String?> ensureCached(String url, {bool priority = false}) async {
    asked.add(url);
    return answer;
  }
}

class _Catalog extends CatalogNotifier {
  @override
  Future<List<Wallpaper>> build() async => const [
    Wallpaper(
      id: 'other',
      title: 'Other',
      kind: WallpaperKind.live,
      key: 'wallpapers/murugan/other.mp4',
    ),
    Wallpaper(
      id: '1c340988-23d0-405b-9931-2778ad03c17e',
      title: 'Sivan 5',
      category: 'sivan',
      kind: WallpaperKind.live,
      key: 'wallpapers/sivan/1c340988.mp4',
    ),
  ];
}

class _Auth implements AuthService {
  bool signedIn = false;

  @override
  AuthUserState get currentState => signedIn
      ? AuthUserState.authenticated(userId: 'u')
      : AuthUserState.unauthenticated();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePrefetch prefetch;
  late _Auth auth;

  setUp(() {
    DeviceQuality.debugSetTier(DeviceTier.mid);
    DataSaver.debugSet(false);
  });

  tearDown(() {
    DeviceQuality.resetForTesting();
    DataSaver.debugSet(null);
  });

  Future<ProviderContainer> boot({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    final stored = await SharedPreferences.getInstance();
    prefetch = _FakePrefetch();
    auth = _Auth();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(stored),
        wallpaperPrefetchServiceProvider.overrideWithValue(prefetch),
        catalogProvider.overrideWith(_Catalog.new),
        authServiceProvider.overrideWithValue(auth),
      ],
    );
    addTearDown(c.dispose);
    // The splash reads it before its sign-in attempt.
    c.read(launchClipProvider);
    return c;
  }

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'waits for Google\'s surface, then plays the poster\'s own clip',
    () async {
      final c = await boot();
      c.read(launchClipProvider.notifier).wallUp(RegionalPoster.sivan);
      await settle();
      expect(prefetch.asked, isEmpty, reason: 'the sign-in path stays small');
      expect(c.read(launchClipProvider), isNull);

      SignInPhase.signals.add(SignInSignal.surfaceShown);
      await settle();
      await settle();
      expect(prefetch.asked, [
        'https://cdn.test/wallpapers/sivan/1c340988.mp4',
      ]);
      expect(c.read(launchClipProvider), '/cache/clip.mp4');
    },
  );

  test('an attempt that ended without a surface also opens the gate', () async {
    final c = await boot();
    c.read(launchClipProvider.notifier).wallUp(RegionalPoster.sivan);
    SignInPhase.signals.add(SignInSignal.settled);
    await settle();
    await settle();
    expect(c.read(launchClipProvider), '/cache/clip.mp4');
  });

  test('the surface before the wall is remembered', () async {
    final c = await boot();
    SignInPhase.signals.add(SignInSignal.surfaceShown);
    c.read(launchClipProvider.notifier).wallUp(RegionalPoster.sivan);
    await settle();
    await settle();
    expect(c.read(launchClipProvider), '/cache/clip.mp4');
  });

  Future<void> expectPoster(
    ProviderContainer c, {
    RegionalPoster poster = RegionalPoster.sivan,
  }) async {
    c.read(launchClipProvider.notifier).wallUp(poster);
    SignInPhase.signals.add(SignInSignal.surfaceShown);
    await settle();
    await settle();
    expect(c.read(launchClipProvider), isNull);
  }

  test('Data Saver keeps the poster and downloads nothing', () async {
    final c = await boot();
    DataSaver.debugSet(true);
    await expectPoster(c);
    expect(prefetch.asked, isEmpty);
  });

  test('a poster-rule phone keeps the poster and downloads nothing', () async {
    final c = await boot();
    DeviceQuality.debugSetTier(DeviceTier.low);
    await expectPoster(c);
    expect(prefetch.asked, isEmpty);
  });

  test('a signed-in session downloads nothing', () async {
    final c = await boot();
    auth.signedIn = true;
    await expectPoster(c);
    expect(prefetch.asked, isEmpty);
  });

  test('a failed transfer keeps the poster, silently', () async {
    final c = await boot();
    prefetch.answer = null;
    await expectPoster(c);
    expect(prefetch.asked, hasLength(1));
  });

  test('a poster whose clip is not in the catalog keeps the poster', () async {
    final c = await boot();
    await expectPoster(c, poster: RegionalPoster.ayyappan);
    expect(prefetch.asked, isEmpty);
  });

  test('a control install gets its clip too: the test is over', () async {
    final c = await boot(prefs: {Experiments.regionalKey: 'control'});
    c.read(launchClipProvider.notifier).wallUp(RegionalPoster.sivan);
    SignInPhase.signals.add(SignInSignal.surfaceShown);
    await settle();
    await settle();
    expect(c.read(launchClipProvider), '/cache/clip.mp4');
  });

  test('the kill switch never plays a clip', () async {
    final c = await boot(prefs: {Experiments.regionalOffKey: true});
    await expectPoster(c, poster: RegionalPoster.murugan);
    expect(prefetch.asked, isEmpty);
  });

  // No catalog row for Murugan in this fake: its wall cut is fetched by CDN key, never by the feed's
  // 9.5 MB file.
  test('Murugan downloads its launch cut after the surface', () async {
    final c = await boot();
    c.read(launchClipProvider.notifier).wallUp(RegionalPoster.murugan);
    await settle();
    expect(prefetch.asked, isEmpty, reason: 'the sign-in path stays small');

    SignInPhase.signals.add(SignInSignal.surfaceShown);
    await settle();
    await settle();
    expect(prefetch.asked, [
      'https://cdn.test/${RegionalPoster.murugan.launchClipKey}',
    ]);
    expect(c.read(launchClipProvider), '/cache/clip.mp4');
  });

  test('Data Saver keeps Murugan on the poster too', () async {
    final c = await boot();
    DataSaver.debugSet(true);
    await expectPoster(c, poster: RegionalPoster.murugan);
    expect(prefetch.asked, isEmpty);
  });

  test('every poster names the catalog row it was cut from', () {
    expect(
      RegionalPoster.all.map((p) => p.wallpaperId).toSet(),
      hasLength(RegionalPoster.all.length),
    );
  });
}
