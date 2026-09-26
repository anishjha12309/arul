// Only a SUCCESSFUL set arms the review ask: a static apply, a live apply that reached the chooser,
// or a ringtone set. A failure, a premium refusal or a trip to the grant screen arms nothing.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/review/domain/review_ledger.dart';
import 'package:arul/features/ringtones/data/ringtone_set_service.dart';
import 'package:arul/features/ringtones/providers/ringtone_set_provider.dart';
import 'package:arul/features/wallpapers/data/wallpaper_apply_service.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_apply_provider.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_prefetch_provider.dart';

import 'review_fakes.dart';

class _ApplyService implements WallpaperApplyService {
  _ApplyService(this.tmpDir, {this.fails = false});

  final Directory tmpDir;
  final bool fails;

  @override
  Future<String> resolveUrl(Wallpaper w) async => 'https://cdn/${w.key}';

  @override
  Future<String> downloadUrl(Wallpaper w, {required MediaUseAction action}) =>
      Future.value('https://cdn/${w.key}');

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async =>
      File('${tmpDir.path}/$filename')..writeAsBytesSync(List.filled(8, 1));

  @override
  Future<void> applyStaticWallpaper(File file, ApplyTarget target) async {
    if (fails) {
      throw const WallpaperApplyException('boom', code: 'applyFailed');
    }
  }

  @override
  Future<LiveApplyResult> applyLiveWallpaper(
    File file,
    ApplyTarget target,
  ) async {
    if (fails) {
      throw const WallpaperApplyException('boom', code: 'applyFailed');
    }
    return const LiveApplyResult(LiveApplyOutcome.chooser);
  }
}

class _NoPrefetch extends WallpaperPrefetchService {
  _NoPrefetch() : super(cdnBaseUrl: 'https://cdn');

  @override
  Future<String?> cachedPathOrNull(String url) async => null;
}

class _SetService implements RingtoneSetService {
  _SetService({this.canWrite = true, this.fails = false});

  final bool canWrite;
  final bool fails;

  @override
  Future<bool> canWriteSettings() async => canWrite;

  @override
  Future<void> openWriteSettings() async {}

  @override
  Future<String> fetchSignedUrl(String id) async {
    if (fails) {
      throw const RingtoneSetException('Premium', premiumRequired: true);
    }
    return 'https://cdn/$id';
  }

  @override
  Future<File> downloadFile(
    String url,
    String filename,
    void Function(double) onProgress,
  ) async => File(filename);

  @override
  Future<RingtoneRef?> setRingtone(
    File file,
    RingtoneTarget target, {
    required String title,
    required String mime,
  }) async => null;

  @override
  Future<RingtoneRef?> readCurrentRingtone() async => null;
}

Wallpaper _wallpaper(WallpaperKind kind) => Wallpaper(
  id: 'w1',
  title: 'Vel',
  category: 'murugan',
  kind: kind,
  key: kind == WallpaperKind.live ? 'wallpapers/w1.mp4' : 'wallpapers/w1.jpg',
);

const _tone = Ringtone(
  id: 'r1',
  title: 'Kavasam',
  category: 'murugan',
  audioKey: 'r1.mp3',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late SharedPreferences prefs;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('arul_review_arm');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmpDir.path,
        );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    tmpDir.deleteSync(recursive: true);
  });

  ProviderContainer boot({
    WallpaperApplyService? apply,
    RingtoneSetService? set,
  }) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        analyticsServiceProvider.overrideWithValue(RecordingAnalytics()),
        wallpaperPrefetchServiceProvider.overrideWithValue(_NoPrefetch()),
        if (apply != null)
          wallpaperApplyServiceProvider.overrideWithValue(apply),
        if (set != null) ringtoneSetServiceProvider.overrideWithValue(set),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ReviewTrigger? armed() => prefs.getString(ReviewLedger.armedLaunchKey) == null
      ? null
      : ReviewLedger(prefs).armedTrigger;

  test('a static apply arms it', () async {
    final c = boot(apply: _ApplyService(tmpDir));
    await c
        .read(wallpaperApplyProvider.notifier)
        .apply(_wallpaper(WallpaperKind.image), target: ApplyTarget.both);
    expect(c.read(wallpaperApplyProvider), isA<WallpaperApplySuccess>());
    expect(armed(), ReviewTrigger.wallpaperStatic);
    // Armed by THIS launch -> the ask waits for the next cold open.
    expect(ReviewLedger(prefs).armedBeforeThisLaunch, isFalse);
  });

  test('a live apply that reached the chooser arms it', () async {
    final c = boot(apply: _ApplyService(tmpDir));
    await c
        .read(wallpaperApplyProvider.notifier)
        .apply(_wallpaper(WallpaperKind.live), target: ApplyTarget.both);
    expect(armed(), ReviewTrigger.wallpaperLive);
  });

  test('a failed apply arms nothing', () async {
    final c = boot(apply: _ApplyService(tmpDir, fails: true));
    for (final kind in WallpaperKind.values) {
      await c
          .read(wallpaperApplyProvider.notifier)
          .apply(_wallpaper(kind), target: ApplyTarget.both);
      expect(c.read(wallpaperApplyProvider), isA<WallpaperApplyError>());
    }
    expect(armed(), isNull);
  });

  test('a ringtone set arms it', () async {
    final c = boot(set: _SetService());
    await c
        .read(ringtoneSetProvider.notifier)
        .setRingtone(_tone, RingtoneTarget.ringtone);
    expect(c.read(ringtoneSetProvider), isA<RingtoneSetSuccess>());
    expect(armed(), ReviewTrigger.ringtone);
  });

  test('a set refused or sent to the grant screen arms nothing', () async {
    final refused = boot(set: _SetService(fails: true));
    await refused
        .read(ringtoneSetProvider.notifier)
        .setRingtone(_tone, RingtoneTarget.ringtone);
    expect(refused.read(ringtoneSetProvider), isA<RingtoneSetError>());

    final noGrant = boot(set: _SetService(canWrite: false));
    await noGrant
        .read(ringtoneSetProvider.notifier)
        .setRingtone(_tone, RingtoneTarget.ringtone);
    expect(noGrant.read(ringtoneSetProvider), isA<RingtoneSetIdle>());

    expect(armed(), isNull);
  });

  test('a set with no prefs store still succeeds', () async {
    final container = ProviderContainer(
      overrides: [
        analyticsServiceProvider.overrideWithValue(RecordingAnalytics()),
        ringtoneSetServiceProvider.overrideWithValue(_SetService()),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(ringtoneSetProvider.notifier)
        .setRingtone(_tone, RingtoneTarget.ringtone);
    expect(container.read(ringtoneSetProvider), isA<RingtoneSetSuccess>());
  });
}
