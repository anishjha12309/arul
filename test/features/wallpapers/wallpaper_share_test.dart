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
import 'package:arul/features/wallpapers/data/direct_share_service.dart';
import 'package:arul/features/wallpapers/data/share_watermark_service.dart';
import 'package:arul/features/wallpapers/data/wallpaper_apply_service.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_apply_provider.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_prefetch_provider.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_share_provider.dart';
import 'package:flutter/widgets.dart' show Locale;

import 'package:arul/core/providers/locale_provider.dart';

// ─── Fakes ────────────────────────────────────────────────────────────────────

class _FakeApplyService implements WallpaperApplyService {
  _FakeApplyService(this.tmpDir);

  final Directory tmpDir;

  @override
  Future<String> resolveUrl(Wallpaper w) async =>
      'https://cdn.example.com/${w.key}';

  @override
  Future<String> downloadUrl(Wallpaper w, {required MediaUseAction action}) {
    downloadActions.add(action);
    return Future.value('https://cdn.example.com/${w.key}');
  }

  /// Every action the share path asked a signed URL for -> the share must NEVER request `apply`.
  /// That would count a share toward `apply_count` and rank wallpapers nobody kept to the top of All.
  final downloadActions = <MediaUseAction>[];

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
  Future<LiveApplyResult> applyLiveWallpaper(
    File file,
    ApplyTarget target,
  ) async => const LiveApplyResult(LiveApplyOutcome.chooser);
}

class _FakeWatermarkService implements ShareWatermarkService {
  _FakeWatermarkService({
    this.failWith,
    this.failTimes,
    this.unsupportedSdkInt,
  });

  /// Thrown by watermark attempts -> every one of them, or just the first [failTimes] when that is set.
  final ShareWatermarkException? failWith;

  /// null means [failWith] applies forever; N fails only the first N attempts -> that is how the one-shot retry runs.
  final int? failTimes;

  /// Non-null -> this device cannot watermark VIDEO and reports this API level.
  /// Stands in for anything below API 31 (androidx/media#2535).
  final int? unsupportedSdkInt;

  final planned = <String>[];

  /// Watermark attempts made across both media kinds -> the retry assertions read this.
  int attempts = 0;

  @override
  WatermarkSpec plan({required String wallpaperId, String? userId}) {
    planned.add(wallpaperId);
    return const WatermarkSpec(logoCorner: 0, code: 'AR-TESTXY');
  }

  @override
  Future<({bool supported, int sdkInt})> videoWatermarkSupport() async =>
      (supported: unsupportedSdkInt == null, sdkInt: unsupportedSdkInt ?? 34);

  File _attempt(String outPath) {
    attempts++;
    final f = failWith;
    if (f != null && (failTimes == null || attempts <= failTimes!)) throw f;
    return File(outPath)..writeAsBytesSync(List.filled(16, 9));
  }

  @override
  Future<File> watermarkImage(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async => _attempt(outPath);

  @override
  Future<File> watermarkVideo(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    // Mirrors the real service -> the support probe runs BEFORE any work, so an unsupported device renders nothing.
    final sdk = unsupportedSdkInt;
    if (sdk != null) throw ShareWatermarkUnsupportedException(sdk);
    return _attempt(outPath);
  }

  @override
  Future<Uint8List> renderOverlayPng(
    WatermarkSpec spec, {
    required int width,
    required int height,
  }) async => Uint8List(0);
}

/// The real prefetch cache manager needs sqflite and app-support dirs absent under `flutter test` -> its lookup hangs.
/// Stub it out -> no cached copy means the notifier takes the plain download path.
class _NoPrefetch extends WallpaperPrefetchService {
  _NoPrefetch() : super(cdnBaseUrl: 'https://cdn.example.com');

  @override
  Future<String?> cachedPathOrNull(String url) async => null;
}

class _FakeReferralRepository implements ReferralRepository {
  _FakeReferralRepository({this.code});

  /// Null means the account has no referral code yet, or the summary never loaded -> the share falls back to the listing.
  final String? code;

  @override
  Future<List<ReferralModel>> getReferrals(String referrerId) async => const [];

  @override
  Future<ReferralSummary> getReferralSummary() async => ReferralSummary(
    referralCode: code,
    referrals: const [],
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

/// Stands in for the native targeted-intent channel -> [installed] false is the common case on test and real devices.
/// That is what makes the notifier fall through to the system sheet.
class _FakeDirectShare implements DirectShareService {
  _FakeDirectShare({this.installed = false});

  final bool installed;
  final calls = <({String filePath, String mimeType, String text})>[];

  @override
  Future<bool> shareToWhatsApp({
    required String filePath,
    required String mimeType,
    required String text,
  }) async {
    calls.add((filePath: filePath, mimeType: mimeType, text: text));
    return installed;
  }
}

/// The default caption builder mirrors `l10n.wallpaperShareCaption`'s shape.
/// One line, then the link ALONE on the last line, and no second URL anywhere.
String _caption(String link) => 'More devotional wallpapers on Arul:\n$link';

/// The share link stamps the sharer's UI language -> the suite must be able to say what it is.
/// The real notifier reads it from SharedPreferences.
class _FixedLocale extends LocaleNotifier {
  _FixedLocale(this._locale);

  final Locale _locale;

  @override
  Locale build() => _locale;
}

ProviderContainer _container({
  required WallpaperApplyService service,
  required _FakeWatermarkService watermark,
  _RecordingAnalytics? analytics,
  List<ShareParams>? sheetCalls,
  DirectShareService? directShare,
  ReferralRepository? referrals,
  Locale locale = const Locale('en'),
}) {
  return ProviderContainer(
    overrides: [
      localeProvider.overrideWith(() => _FixedLocale(locale)),
      wallpaperApplyServiceProvider.overrideWithValue(service),
      wallpaperPrefetchServiceProvider.overrideWithValue(_NoPrefetch()),
      shareWatermarkServiceProvider.overrideWithValue(watermark),
      referralRepositoryProvider.overrideWithValue(
        referrals ?? _FakeReferralRepository(),
      ),
      directShareServiceProvider.overrideWithValue(
        directShare ?? _FakeDirectShare(),
      ),
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

  // The share flow probes getTemporaryDirectory() for the apply flow's cached download before hitting the network.
  // Mock path_provider so the probe finds a fresh temp dir -> no cache hit means the normal download-then-share path.
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
          .share(_wallpaper(), buildCaption: _caption);

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
      expect(params.text, contains('More devotional wallpapers on Arul'));
      expect(params.text, contains('https://arul.hsrutility.com/w/w1'));

      expect(analytics.events, contains('wallpaper_shared'));
      expect(analytics.events, isNot(contains('share_watermark_failed')));
      expect(analytics.props['wallpaper_shared'], {
        'wallpaper_id': 'w1',
        'type': 'image',
        'category': 'murugan',
        'result': 'success',
        'watermarked': true,
        'link_attributed': false,
        'channel': 'sheet',
      });
    });

    test('the outgoing caption carries EXACTLY ONE link', () async {
      // The caption used to be `'$message\n$link'` where `message` itself ended in a hard-coded marketing URL.
      // Every shared wallpaper went out with two competing URLs -> the recipient could tap the one that credits nobody.
      // The caption owns the link now -> a second one cannot be appended by accident.
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(),
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      final text = sheetCalls.single.text!;
      expect(
        RegExp(r'https?://').allMatches(text),
        hasLength(1),
        reason: 'a second URL splits the tap and loses the attribution',
      );
      // And the one link is the wallpaper deep link, not the store listing.
      expect(text, contains('arul.hsrutility.com/w/'));
      // And it is the LAST thing in the message -> messengers preview a trailing link and bury an inline one.
      expect(text.trimRight().split('\n').last, startsWith('https://'));
    });

    test('the link stamps the language of the sharer as ilang, so a FRESH '
        'install opens in it and an existing one does not change', () async {
      // The caption is already in the sharer's language -> without this the friend who installs lands in English.
      // `ilang`, not `lang`, is what keeps it to FRESH installs -> the App Link parser ignores it, the Play referrer does not.
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(),
        sheetCalls: sheetCalls,
        locale: const Locale('ta'),
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      final text = sheetCalls.single.text!;
      expect(text, contains('ilang=ta'));
      expect(
        text,
        isNot(contains('lang=ta&')),
        reason: 'plain lang= would override the language they chose',
      );
      expect(
        RegExp(r'[?&]lang=').hasMatch(text),
        isFalse,
        reason: 'only ilang rides on a share',
      );
    });

    test('WhatsApp takes the share when present, and the sheet never '
        'opens', () async {
      final analytics = _RecordingAnalytics();
      final sheetCalls = <ShareParams>[];
      final direct = _FakeDirectShare(installed: true);
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(),
        analytics: analytics,
        sheetCalls: sheetCalls,
        directShare: direct,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      // The FILE went to WhatsApp -> that is why this path is a native targeted intent.
      // A `whatsapp://send?text=` deep link would have dropped the file and sent a bare caption.
      expect(direct.calls, hasLength(1));
      expect(direct.calls.single.filePath, endsWith('-wm-AR-TESTXY.jpg'));
      expect(direct.calls.single.mimeType, 'image/jpeg');
      expect(direct.calls.single.text, contains('arul.hsrutility.com/w/w1'));

      expect(sheetCalls, isEmpty);
      expect(analytics.props['wallpaper_shared']?['channel'], 'whatsapp');
      expect(c.read(wallpaperShareProvider), isA<WallpaperShareIdle>());
    });

    test('a share asks for a SHARE grant, never an apply one', () async {
      // The signed-url route counts only `apply` toward apply_count -> All stays ordered by what people kept.
      // Not by what they merely forwarded.
      final service = _FakeApplyService(tmpDir);
      final c = _container(
        service: service,
        watermark: _FakeWatermarkService(),
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      expect(service.downloadActions, isNotEmpty);
      expect(service.downloadActions, everyElement(MediaUseAction.share));
    });

    test('an unattributed link is REPORTED as unattributed', () async {
      // `flutter test` has no dart-defines -> `AppConfig.hasBackend` is false and the referral lookup is skipped.
      // The share then ships the plain Play listing -> correct behaviour, and what matters is that it is DECLARED.
      // `link_attributed` exists so a share that can never be credited to its sender is visible in the funnel.
      // A code IS present on the fake repository here, and the flag must still say false -> the link carries no referrer.
      final analytics = _RecordingAnalytics();
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(),
        analytics: analytics,
        sheetCalls: sheetCalls,
        referrals: _FakeReferralRepository(code: 'ARUL123'),
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      final text = sheetCalls.single.text!;
      expect(text, isNot(contains('referrer=')));
      expect(analytics.props['wallpaper_shared']?['link_attributed'], false);
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
          .share(_wallpaper(kind: WallpaperKind.live), buildCaption: _caption);

      final file = sheetCalls.single.files!.single;
      expect(file.path, endsWith('-wm-AR-TESTXY.mp4'));
      expect(file.mimeType, 'video/mp4');
      expect(sheetCalls.single.fileNameOverrides, ['arul-murugan-vel.mp4']);
    });

    test('a device that CANNOT watermark video shares the clean original and '
        'tracks share_watermark_skipped', () async {
      // Below API 31 Media3's Transformer resolves an API-31-only class and takes the process down (androidx/media#2535).
      // So the export is not attempted at all -> the share must still go out, because untraced beats not happening.
      final analytics = _RecordingAnalytics();
      final sheetCalls = <ShareParams>[];
      final watermark = _FakeWatermarkService(unsupportedSdkInt: 28);
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: watermark,
        analytics: analytics,
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(kind: WallpaperKind.live), buildCaption: _caption);

      expect(c.read(wallpaperShareProvider), isA<WallpaperShareIdle>());
      expect(sheetCalls, hasLength(1));
      final file = sheetCalls.single.files!.single;
      expect(file.path, isNot(contains('-wm-')));
      expect(file.path, endsWith('w1.mp4'));
      expect(file.mimeType, 'video/mp4');
      // The recipient still gets a branded filename and the referral caption.
      expect(sheetCalls.single.fileNameOverrides, ['arul-murugan-vel.mp4']);

      // A skip is NOT a failure -> never report it as one.
      expect(analytics.events, isNot(contains('share_watermark_failed')));
      expect(analytics.props['share_watermark_skipped'], {
        'wallpaper_id': 'w1',
        'type': 'live',
        'sdk_int': 28,
      });
      expect(analytics.props['wallpaper_shared']?['watermarked'], false);
      // Not retried -> the answer cannot change on this device.
      expect(watermark.attempts, 0);
    });

    test('a STATIC share is still watermarked on a device that cannot do '
        'video', () async {
      // The static path never touches Media3 -> the API-31 skip must not leak into it.
      // Those shares stay traceable on every Android version.
      final sheetCalls = <ShareParams>[];
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: _FakeWatermarkService(unsupportedSdkInt: 28),
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      expect(
        sheetCalls.single.files!.single.path,
        endsWith('-wm-AR-TESTXY.jpg'),
      );
    });

    test('watermark failure on a CAPABLE device fails the share rather than '
        'shipping an untraced copy', () async {
      final analytics = _RecordingAnalytics();
      final sheetCalls = <ShareParams>[];
      final watermark = _FakeWatermarkService(
        failWith: const ShareWatermarkException('encode blew up'),
      );
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: watermark,
        analytics: analytics,
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      // NOTHING left the device.
      expect(sheetCalls, isEmpty);
      final state = c.read(wallpaperShareProvider);
      expect(state, isA<WallpaperShareError>());
      expect((state as WallpaperShareError).premiumRequired, isFalse);
      expect(state.isNetwork, isFalse);

      expect(analytics.events, isNot(contains('wallpaper_shared')));
      expect(analytics.props['share_watermark_failed'], {
        'wallpaper_id': 'w1',
        'type': 'image',
        'reason': 'encode blew up',
      });
      // Tried twice before giving up.
      expect(watermark.attempts, 2);
    });

    test('a transient watermark failure is retried once and the share '
        'succeeds', () async {
      final analytics = _RecordingAnalytics();
      final sheetCalls = <ShareParams>[];
      final watermark = _FakeWatermarkService(
        failWith: const ShareWatermarkException('busy'),
        failTimes: 1,
      );
      final c = _container(
        service: _FakeApplyService(tmpDir),
        watermark: watermark,
        analytics: analytics,
        sheetCalls: sheetCalls,
      );
      addTearDown(c.dispose);

      await c
          .read(wallpaperShareProvider.notifier)
          .share(_wallpaper(), buildCaption: _caption);

      expect(watermark.attempts, 2);
      expect(sheetCalls, hasLength(1));
      expect(sheetCalls.single.files!.single.path, contains('-wm-'));
      expect(analytics.props['wallpaper_shared']?['watermarked'], true);
      expect(analytics.events, isNot(contains('share_watermark_failed')));
      expect(c.read(wallpaperShareProvider), isA<WallpaperShareIdle>());
    });
  });
}
