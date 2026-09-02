// One line decides whether a live apply is a hand-off or a finished apply -> the two are opposite in every way.
// chooser -> Idle, pending flags LEFT SET, never a success claim, `confirmed: false`.
// The flags stay because the OS chooser is open over us and may recreate the Activity.
// staticFallback -> Success(staticFallback), pending flags CLEARED, `confirmed: true` plus `fallback: true`.
// Leaving `pending_apply_is_live` set would have apply_restore treat a finished apply as a chooser still open.
// `wallpaper_apply_failed` must carry the native code and must NOT fire before `wallpaper_apply_attempt` did.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/wallpapers/data/wallpaper_apply_service.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_apply_provider.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_prefetch_provider.dart';

// ─── Fakes ────────────────────────────────────────────────────────────────────

class _FakeApplyService implements WallpaperApplyService {
  _FakeApplyService(
    this.tmpDir, {
    this.live = const LiveApplyResult(LiveApplyOutcome.chooser),
    this.liveThrows,
    this.downloadThrows,
  });

  final Directory tmpDir;

  /// What the native channel reports for a live apply.
  final LiveApplyResult live;

  /// Raised instead, standing in for a native PlatformException the service already translated.
  /// Its `code` is what the failure event reports.
  final WallpaperApplyException? liveThrows;

  /// Raised from the gated signed-url call -> BEFORE the attempt event fires.
  final WallpaperApplyException? downloadThrows;

  int liveCalls = 0;

  @override
  Future<String> resolveUrl(Wallpaper w) async =>
      'https://cdn.example.com/${w.key}';

  @override
  Future<String> downloadUrl(Wallpaper w, {required MediaUseAction action}) {
    final t = downloadThrows;
    if (t != null) throw t;
    return Future.value('https://cdn.example.com/${w.key}');
  }

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async {
    onProgress(1.0);
    return File('${tmpDir.path}/$filename')
      ..writeAsBytesSync(List.filled(16, 7));
  }

  @override
  Future<void> applyStaticWallpaper(File file, ApplyTarget target) async {}

  @override
  Future<LiveApplyResult> applyLiveWallpaper(
    File file,
    ApplyTarget target,
  ) async {
    liveCalls++;
    final t = liveThrows;
    if (t != null) throw t;
    return live;
  }
}

/// The real prefetch service needs sqflite and app-support dirs that do not exist under `flutter test`.
/// Stub it so the notifier takes the plain download path.
class _NoPrefetch extends WallpaperPrefetchService {
  _NoPrefetch() : super(cdnBaseUrl: 'https://cdn.example.com');

  @override
  Future<String?> cachedPathOrNull(String url) async => null;
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

Wallpaper _live({String id = 'w1'}) => Wallpaper(
  id: id,
  title: 'Murugan Vel',
  category: 'murugan',
  kind: WallpaperKind.live,
  key: 'wallpapers/murugan/$id.mp4',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('arul_live_fallback_test');
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

  Future<({ProviderContainer container, SharedPreferences prefs})> boot(
    _FakeApplyService service,
    _RecordingAnalytics analytics,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        wallpaperApplyServiceProvider.overrideWithValue(service),
        wallpaperPrefetchServiceProvider.overrideWithValue(_NoPrefetch()),
        analyticsServiceProvider.overrideWithValue(analytics),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, prefs: prefs);
  }

  group('live apply outcome', () {
    test('chooser finishes Idle with the pending flags left in place', () async {
      final analytics = _RecordingAnalytics();
      final service = _FakeApplyService(tmpDir);
      final b = await boot(service, analytics);

      await b.container
          .read(wallpaperApplyProvider.notifier)
          .apply(
            _live(),
            target: ApplyTarget.both,
            feedPageIndex: 3,
            category: 'murugan',
          );

      expect(service.liveCalls, 1);
      expect(
        b.container.read(wallpaperApplyProvider),
        isA<WallpaperApplyIdle>(),
      );

      // The chooser may recreate the Activity -> the flags are how the feed gets the user back to the card they left.
      expect(b.prefs.getBool(appliedWallpaperPendingKey), isTrue);
      expect(b.prefs.getBool(pendingApplyIsLiveKey), isTrue);
      expect(b.prefs.getInt(pendingApplyPageIndexKey), 3);
      expect(b.prefs.getString(pendingApplyCategoryKey), 'murugan');

      expect(analytics.events, contains('wallpaper_apply_attempt'));
      expect(analytics.events, contains('wallpaper_applied'));
      expect(
        analytics.events,
        isNot(contains('wallpaper_apply_live_fallback')),
      );
      expect(analytics.props['wallpaper_applied']!['confirmed'], isFalse);
      expect(
        analytics.props['wallpaper_applied']!.containsKey('fallback'),
        isFalse,
      );
    });

    test('staticFallback succeeds, clears the pending flags and fires the '
        'tripwire', () async {
      final analytics = _RecordingAnalytics();
      final service = _FakeApplyService(
        tmpDir,
        live: const LiveApplyResult(
          LiveApplyOutcome.staticFallback,
          reason: 'featureMissing',
        ),
      );
      final b = await boot(service, analytics);

      await b.container
          .read(wallpaperApplyProvider.notifier)
          .apply(
            _live(),
            target: ApplyTarget.both,
            feedPageIndex: 3,
            category: 'murugan',
          );

      final state = b.container.read(wallpaperApplyProvider);
      expect(state, isA<WallpaperApplySuccess>());
      expect((state as WallpaperApplySuccess).isLive, isTrue);
      expect(state.staticFallback, isTrue);

      // Nothing is pending -> the wallpaper is already applied.
      // A surviving `pending_apply_is_live` would make apply_restore restore as if the chooser were still open.
      expect(b.prefs.getBool(appliedWallpaperPendingKey), isNull);
      expect(b.prefs.getBool(pendingApplyIsLiveKey), isNull);
      expect(b.prefs.getInt(pendingApplyPageIndexKey), isNull);
      expect(b.prefs.getString(pendingApplyCategoryKey), isNull);

      expect(analytics.props['wallpaper_apply_live_fallback'], {
        'wallpaper_id': 'w1',
        'category': 'murugan',
        'type': 'live',
        'target': 'both',
        'reason': 'featureMissing',
      });
      // Confirmed, and flagged -> "confirmed is true only on a static apply" stays readable.
      expect(analytics.props['wallpaper_applied'], {
        'wallpaper_id': 'w1',
        'category': 'murugan',
        'type': 'live',
        'target': 'both',
        'confirmed': true,
        'fallback': true,
      });
    });

    test('chooserUnavailable is reported as its own reason', () async {
      final analytics = _RecordingAnalytics();
      final service = _FakeApplyService(
        tmpDir,
        live: const LiveApplyResult(
          LiveApplyOutcome.staticFallback,
          reason: 'chooserUnavailable',
        ),
      );
      final b = await boot(service, analytics);

      await b.container
          .read(wallpaperApplyProvider.notifier)
          .apply(_live(), target: ApplyTarget.both);

      expect(
        analytics.props['wallpaper_apply_live_fallback']!['reason'],
        'chooserUnavailable',
      );
    });
  });

  group('wallpaper_apply_failed', () {
    for (final code in const [
      'unsupported',
      'applyFailed',
      'manufacturerRestriction',
      'permissionDenied',
      'sourceNotFound',
    ]) {
      test('carries the native code $code', () async {
        final analytics = _RecordingAnalytics();
        final service = _FakeApplyService(
          tmpDir,
          liveThrows: WallpaperApplyException('boom', code: code),
        );
        final b = await boot(service, analytics);

        await b.container
            .read(wallpaperApplyProvider.notifier)
            .apply(_live(), target: ApplyTarget.both, feedPageIndex: 3);

        expect(
          b.container.read(wallpaperApplyProvider),
          isA<WallpaperApplyError>(),
        );
        expect(analytics.props['wallpaper_apply_failed'], {
          'wallpaper_id': 'w1',
          'category': 'murugan',
          'type': 'live',
          'target': 'both',
          'code': code,
        });
        // A failed apply is not pending anything.
        expect(b.prefs.getBool(appliedWallpaperPendingKey), isNull);
      });
    }

    test('does not fire for a failure before the attempt event', () async {
      final analytics = _RecordingAnalytics();
      final service = _FakeApplyService(
        tmpDir,
        downloadThrows: const WallpaperApplyException(
          'Premium subscription required',
          premiumRequired: true,
        ),
      );
      final b = await boot(service, analytics);

      await b.container
          .read(wallpaperApplyProvider.notifier)
          .apply(_live(), target: ApplyTarget.both);

      // The numerator must stay inside its denominator -> no attempt was recorded, so no failure may be either.
      expect(analytics.events, isNot(contains('wallpaper_apply_attempt')));
      expect(analytics.events, isNot(contains('wallpaper_apply_failed')));
      expect(service.liveCalls, 0);
    });
  });
}
