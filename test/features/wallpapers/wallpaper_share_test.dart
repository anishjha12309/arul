import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart'
    show ShareParams, ShareResult, ShareResultStatus;

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/referral/domain/referral_repository.dart';
import 'package:arul/features/referral/domain/referral_summary.dart';
import 'package:arul/data/models/referral_model.dart';
import 'package:arul/features/wallpapers/data/share_watermark_service.dart';
import 'package:arul/features/wallpapers/data/wallpaper_apply_service.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_apply_provider.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_prefetch_provider.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_share_provider.dart';

// ─── Fakes ────────────────────────────────────────────────────────────────────

class _FakeApplyService implements WallpaperApplyService {
  _FakeApplyService(this.tmpDir);

  final Directory tmpDir;

  @override
  Future<String> resolveUrl(Wallpaper w) async =>
      'https://cdn.example.com/${w.key}';

  @override
  Future<String> downloadUrl(Wallpaper w) async =>
      'https://cdn.example.com/${w.key}';

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async {
    onProgress(0.5);
    onProgress(1.0);
    final f = File('${tmpDir.path}/$filename');
    f.writeAsBytesSync(List.filled(16, 7));
    return f;
  }

  @override
  Future<void> applyStaticWallpaper(File file, ApplyTarget target) async {}

  @override
  Future<void> applyLiveWallpaper(File file, ApplyTarget target) async {}

  @override
  Future<bool> isOwnLiveWallpaperActive() async => false;
}

class _FakeWatermarkService implements ShareWatermarkService {
  _FakeWatermarkService({this.failWith});

  final ShareWatermarkException? failWith;
  final planned = <String>[];

  @override
  WatermarkSpec plan({required String wallpaperId, String? userId}) {
    planned.add(wallpaperId);
    return const WatermarkSpec(logoCorner: 0, code: 'AR-TESTXY');
  }

  @override
  Future<File> watermarkImage(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    final f = failWith;
    if (f != null) throw f;
    return File(outPath)..writeAsBytesSync(List.filled(16, 9));
  }

  @override
  Future<File> watermarkVideo(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    final f = failWith;
    if (f != null) throw f;
    return File(outPath)..writeAsBytesSync(List.filled(16, 9));
  }

  @override
  Future<Uint8List> renderOverlayPng(
    WatermarkSpec spec, {
    required int width,
    required int height,
  }) async => Uint8List(0);
}

/// The real prefetch service's cache manager needs sqflite + app-support dirs
/// that do not exist under `flutter test` — its lookup hangs, so stub it out
/// (no cached copy → the notifier takes the plain download path).
class _NoPrefetch extends WallpaperPrefetchService {
  _NoPrefetch() : super(cdnBaseUrl: 'https://cdn.example.com');

  @override
  Future<String?> cachedPathOrNull(String url) async => null;
}

class _FakeReferralRepository implements ReferralRepository {
  @override
  Future<List<ReferralModel>> getReferrals(String referrerId) async => const [];

  @override
  Future<ReferralSummary> getReferralSummary() async => const ReferralSummary(
    referralCode: null,
    referrals: [],
    totalRewardDays: 0,
  );
}

class _RecordingAnalytics implements AnalyticsService {
  final events = <String>[];
  final props = <String, Map<String, Object?>>{};

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    events.add(event);
    if (properties != null) props[event] = properties;
  }

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

Wallpaper _wallpaper({
  String id = 'w1',
  String title = 'Murugan Vel',
  WallpaperKind kind = WallpaperKind.image,
}) => Wallpaper(
  id: id,
  title: title,
  category: 'murugan',
  kind: kind,
  key: kind == WallpaperKind.image
      ? 'wallpapers/murugan/$id.jpg'
      : 'wallpapers/murugan/$id.mp4',
);

ProviderContainer _container({
  required WallpaperApplyService service,
  required _FakeWatermarkService watermark,
  _RecordingAnalytics? analytics,
  List<ShareParams>? sheetCalls,
}) {
  return ProviderContainer(
    overrides: [
      wallpaperApplyServiceProvider.overrideWithValue(service),
      wallpaperPrefetchServiceProvider.overrideWithValue(_NoPrefetch()),
      shareWatermarkServiceProvider.overrideWithValue(watermark),
      referralRepositoryProvider.overrideWithValue(_FakeReferralRepository()),
      analyticsServiceProvider.overrideWithValue(
        analytics ?? _RecordingAnalytics(),
      ),
      authStateStreamProvider.overrideWith(
        (ref) => Stream.value(AuthUserState.unauthenticated()),
      ),
      shareSheetLauncherProvider.overrideWithValue((params) async {
        sheetCalls?.add(params);
        return const ShareResult('app', ShareResultStatus.success);
      }),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  // The share flow probes getTemporaryDirectory() for the apply flow's cached
  // download before hitting the network. Mock path_provider so the probe finds
  // a fresh temp dir (no cache hit → the normal fetch→download→share path).
  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('arul_share_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              call.method == 'getTemporaryDirectory' ? tmpDir.path : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    tmpDir.deleteSync(recursive: true);
  });

  group('WallpaperShareNotifier watermarking', () {
    test('shares the watermarked file with the right name, mime type and '
        'analytics', () async {
      final analytics = _RecordingAnalytics();
      final watermark = _FakeWatermarkService();
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: watermark,
        analytics: analytics,
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), message: 'Check this out');

      expect(c.read(wallpaperShareProvider), isA<WallpaperShareIdle>());
      expect(watermark.planned, ['w1']);

      expect(sheetCalls, hasLength(1));
      final params = sheetCalls.single;
      expect(params.files, hasLength(1));
      final file = params.files!.single;
      expect(file.path, contains('-wm-'));
      expect(file.path, endsWith('-wm-AR-TESTXY.jpg'));
      expect(file.mimeType, 'image/jpeg');
      expect(params.fileNameOverrides, ['arul-murugan-vel.jpg']);
      expect(params.text, contains('Check this out'));
      expect(
        params.text,
        contains(
          'https://play.google.com/store/apps/details'
          '?id=com.hsrapps.arul',
        ),
      );

      expect(analytics.events, contains('wallpaper_shared'));
      expect(analytics.events, isNot(contains('share_watermark_failed')));
      expect(analytics.props['wallpaper_shared'], {
        'wallpaper_id': 'w1',
        'type': 'image',
        'category': 'murugan',
        'result': 'success',
        'watermarked': true,
      });
    });

    test('live wallpaper goes through the video path with video/mp4', () async {
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(),
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(kind: WallpaperKind.live), message: 'm');

      final file = sheetCalls.single.files!.single;
      expect(file.path, endsWith('-wm-AR-TESTXY.mp4'));
      expect(file.mimeType, 'video/mp4');
      expect(sheetCalls.single.fileNameOverrides, ['arul-murugan-vel.mp4']);
    });

    test('watermark failure falls back to the ORIGINAL file and tracks '
        'share_watermark_failed', () async {
      final analytics = _RecordingAnalytics();
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(
          failWith: const ShareWatermarkException('encode blew up'),
        ),
        analytics: analytics,
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), message: 'm');

      // Share still happened — with the untouched original.
      expect(sheetCalls, hasLength(1));
      final file = sheetCalls.single.files!.single;
      expect(file.path, isNot(contains('-wm-')));
      expect(file.path, endsWith('w1.jpg'));
      expect(file.mimeType, 'image/jpeg');

      expect(analytics.events, contains('share_watermark_failed'));
      expect(analytics.props['share_watermark_failed'], {
        'wallpaper_id': 'w1',
        'type': 'image',
        'reason': 'encode blew up',
      });
      expect(analytics.props['wallpaper_shared']?['watermarked'], false);
      expect(c.read(wallpaperShareProvider), isA<WallpaperShareIdle>());
    });
  });
}
