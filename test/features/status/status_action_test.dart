// The two premium verbs on a status clip, against fakes for every channel.
// WhatsApp goes composer -> chat -> sheet, each only when the one before answered false.
// The gate is read on EVERY action, cached bytes or not; a 403 routes to the paywall, never a crash.
import 'dart:io';

import 'package:arul/app/widgets/reel/reel_prefetch_service.dart';
import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/providers/auth_providers.dart';
import 'package:arul/features/status/data/status_media_service.dart';
import 'package:arul/features/status/domain/status_video.dart';
import 'package:arul/features/status/providers/status_action_provider.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:arul/features/wallpapers/data/direct_share_service.dart';
import 'package:arul/features/wallpapers/data/share_watermark_service.dart';
import 'package:arul/features/wallpapers/providers/wallpaper_share_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart'
    show ShareParams, ShareResult, ShareResultStatus;

const _clip = StatusVideo(
  id: 'c0ffee00-1c2d-4f3a-9b8e-7d6c5a4b3e2f',
  title: 'Murugan Vel',
  category: 'murugan',
  key: 'statuses/murugan/c0ffee00.mp4',
);

class _FakeMedia implements StatusMediaService {
  _FakeMedia({this.premiumRequired = false, this.save});

  final bool premiumRequired;
  final StatusSaveResult? save;
  final grants = <StatusMediaAction>[];
  final saved = <String>[];

  @override
  Future<String> signedUrl(StatusVideo status, StatusMediaAction action) async {
    grants.add(action);
    if (premiumRequired) {
      throw const StatusMediaException('403', premiumRequired: true);
    }
    return 'https://signed.test/${status.id}';
  }

  @override
  Future<File> downloadFile(
    String url,
    String outPath,
    void Function(double) onProgress,
  ) async {
    onProgress(1);
    return File(outPath)..writeAsBytesSync(List.filled(32, 7));
  }

  @override
  Future<StatusSaveResult> saveToGallery(
    String filePath,
    String displayName,
  ) async {
    saved.add(displayName);
    return save ?? (outcome: StatusSaveOutcome.saved, reason: null);
  }
}

class _FakeDirectShare implements DirectShareService {
  _FakeDirectShare({this.composer = false, this.chat = false});

  final bool composer;
  final bool chat;
  final calls = <String>[];
  String? caption;

  @override
  Future<bool> shareToStatus({required String filePath}) async {
    calls.add('status');
    return composer;
  }

  @override
  Future<bool> shareToWhatsApp({
    required String filePath,
    required String mimeType,
    required String text,
  }) async {
    calls.add('chat');
    caption = text;
    return chat;
  }

  @override
  Future<bool> shareTextToWhatsApp(String text) async => false;
}

class _FakeWatermark implements ShareWatermarkService {
  _FakeWatermark({this.unsupported = false});

  final bool unsupported;

  @override
  WatermarkSpec plan({required String wallpaperId, String? userId}) =>
      const WatermarkSpec(logoCorner: 0, code: 'AR-TEST01');

  @override
  Future<({bool supported, int sdkInt})> videoWatermarkSupport() async =>
      (supported: !unsupported, sdkInt: unsupported ? 28 : 34);

  @override
  Future<File> watermarkVideo(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    if (unsupported) throw ShareWatermarkUnsupportedException(28);
    return File(outPath)..writeAsBytesSync(List.filled(16, 9));
  }

  @override
  Future<File> watermarkImage(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> renderOverlayPng(
    WatermarkSpec spec, {
    required int width,
    required int height,
  }) async => Uint8List(0);
}

/// A real CacheManager starts disk work in its constructor; nothing here ever calls it.
class _NullCache implements CacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoPrefetch extends ReelPrefetchService<StatusVideo> {
  _NoPrefetch()
    : super(
        cdnBaseUrl: 'https://cdn.test',
        cache: _NullCache.new,
        ahead: 1,
        aheadCold: 1,
      );

  @override
  Future<String?> cachedPathOrNull(String url) async => null;
}

class _FixedLocale extends LocaleNotifier {
  @override
  Locale build() => const Locale('ta');
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

  @override
  void register(String key, Object value) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _RecordingAnalytics analytics;
  late List<ShareParams> sheet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('status_action_test');
    analytics = _RecordingAnalytics();
    sheet = [];
    addTearDown(() => tmp.deleteSync(recursive: true));
  });

  ProviderContainer container({
    required _FakeMedia media,
    _FakeDirectShare? direct,
    _FakeWatermark? watermark,
  }) {
    final c = ProviderContainer(
      overrides: [
        statusTempDirProvider.overrideWith((_) async => tmp),
        statusMediaServiceProvider.overrideWithValue(media),
        statusPrefetchServiceProvider.overrideWithValue(_NoPrefetch()),
        directShareServiceProvider.overrideWithValue(
          direct ?? _FakeDirectShare(),
        ),
        shareWatermarkServiceProvider.overrideWithValue(
          watermark ?? _FakeWatermark(),
        ),
        localeProvider.overrideWith(_FixedLocale.new),
        analyticsServiceProvider.overrideWithValue(analytics),
        authStateStreamProvider.overrideWith(
          (ref) => Stream.value(AuthUserState.unauthenticated()),
        ),
        shareSheetLauncherProvider.overrideWithValue((params) async {
          sheet.add(params);
          return const ShareResult('app', ShareResultStatus.success);
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('WhatsApp', () {
    test(
      'the status composer first: no caption, no link, channel=status',
      () async {
        final media = _FakeMedia();
        final direct = _FakeDirectShare(composer: true);
        final c = container(media: media, direct: direct);

        final outcome = await c
            .read(statusActionProvider.notifier)
            .shareToWhatsApp(_clip, buildCaption: (link) => 'cap $link');

        expect(outcome, StatusActionOutcome.done);
        expect(media.grants, [StatusMediaAction.share]);
        expect(direct.calls, ['status']);
        expect(sheet, isEmpty);
        expect(analytics.props['status_shared'], {
          'status_id': _clip.id,
          'category': 'murugan',
          'result': 'unavailable',
          'watermarked': true,
          'channel': 'status',
        });
        expect(c.read(statusActionProvider), isA<StatusActionIdle>());
      },
    );

    test('no composer → a WhatsApp chat carrying ONE /s/ link', () async {
      final direct = _FakeDirectShare(chat: true);
      final c = container(media: _FakeMedia(), direct: direct);

      await c
          .read(statusActionProvider.notifier)
          .shareToWhatsApp(_clip, buildCaption: (link) => 'cap\n$link');

      expect(direct.calls, ['status', 'chat']);
      expect(
        direct.caption,
        'cap\nhttps://arul.hsrutility.com/s/${_clip.id}?ilang=ta',
      );
      expect(RegExp('https://').allMatches(direct.caption!), hasLength(1));
      expect(analytics.props['status_shared']?['channel'], 'chat');
    });

    test('no WhatsApp at all → the system sheet', () async {
      final direct = _FakeDirectShare();
      final c = container(media: _FakeMedia(), direct: direct);

      await c
          .read(statusActionProvider.notifier)
          .shareToWhatsApp(_clip, buildCaption: (link) => link);

      expect(direct.calls, ['status', 'chat']);
      expect(sheet.single.files?.single.mimeType, 'video/mp4');
      expect(analytics.props['status_shared']?['channel'], 'sheet');
      expect(analytics.props['status_shared']?['result'], 'success');
    });

    test(
      'below API 31 the clean clip still goes, marked unwatermarked',
      () async {
        final c = container(
          media: _FakeMedia(),
          direct: _FakeDirectShare(composer: true),
          watermark: _FakeWatermark(unsupported: true),
        );

        await c
            .read(statusActionProvider.notifier)
            .shareToWhatsApp(_clip, buildCaption: (link) => link);

        expect(analytics.props['status_shared']?['watermarked'], false);
      },
    );

    test('a server 403 is a paywall outcome, and nothing leaves', () async {
      final direct = _FakeDirectShare(composer: true);
      final c = container(
        media: _FakeMedia(premiumRequired: true),
        direct: direct,
      );

      final outcome = await c
          .read(statusActionProvider.notifier)
          .shareToWhatsApp(_clip, buildCaption: (link) => link);

      expect(outcome, StatusActionOutcome.premiumRequired);
      expect(direct.calls, isEmpty);
      expect(analytics.events, isNot(contains('status_shared')));
    });

    test('cached bytes skip the download but never the gate', () async {
      final media = _FakeMedia();
      final c = container(
        media: media,
        direct: _FakeDirectShare(composer: true),
      );
      File('${tmp.path}/status-${_clip.id}.mp4').writeAsBytesSync([1, 2, 3]);

      await c
          .read(statusActionProvider.notifier)
          .shareToWhatsApp(_clip, buildCaption: (link) => link);

      expect(media.grants, [StatusMediaAction.share]);
    });
  });

  group('Save', () {
    test(
      'saves the watermarked clip under a fresh name and reports it',
      () async {
        final media = _FakeMedia();
        final c = container(media: media);

        final outcome = await c.read(statusActionProvider.notifier).save(_clip);

        expect(outcome, StatusActionOutcome.done);
        expect(media.grants, [StatusMediaAction.download]);
        expect(media.saved.single, startsWith('arul-murugan-vel-'));
        expect(media.saved.single, endsWith('.mp4'));
        expect(analytics.props['status_saved'], {
          'status_id': _clip.id,
          'category': 'murugan',
          'watermarked': true,
        });
      },
    );

    test('a refused storage prompt is its own outcome', () async {
      final c = container(
        media: _FakeMedia(
          save: (
            outcome: StatusSaveOutcome.permissionDenied,
            reason: 'permission_denied',
          ),
        ),
      );

      final outcome = await c.read(statusActionProvider.notifier).save(_clip);

      expect(outcome, StatusActionOutcome.permissionDenied);
      expect(analytics.props['status_save_failed'], {
        'status_id': _clip.id,
        'reason': 'permission_denied',
      });
    });

    test('a failed write reports the native reason', () async {
      final c = container(
        media: _FakeMedia(
          save: (outcome: StatusSaveOutcome.failed, reason: 'save_failed'),
        ),
      );

      final outcome = await c.read(statusActionProvider.notifier).save(_clip);

      expect(outcome, StatusActionOutcome.failed);
      expect(analytics.props['status_save_failed']?['reason'], 'save_failed');
    });

    test(
      'a server 403 routes to the paywall and logs no save failure',
      () async {
        final c = container(media: _FakeMedia(premiumRequired: true));

        final outcome = await c.read(statusActionProvider.notifier).save(_clip);

        expect(outcome, StatusActionOutcome.premiumRequired);
        expect(analytics.events, isEmpty);
      },
    );
  });

  test('the poster is the key with thumbs/ in front and .jpg behind', () {
    expect(
      _clip.thumbUrl('https://cdn.test'),
      'https://cdn.test/thumbs/statuses/murugan/c0ffee00.jpg',
    );
    expect(
      _clip.videoUrl('https://cdn.test'),
      'https://cdn.test/statuses/murugan/c0ffee00.mp4',
    );
  });

  test('the catalog row parses, unknown category falling into other', () {
    final s = StatusVideo.fromJson({
      'id': 'x',
      'title': 'T',
      'full_key': 'statuses/amman/x.mp4',
      'duration_ms': 21000,
      'feed_rank': 3,
      'published_at': '2026-10-01T00:00:00Z',
    });
    expect(s.category, 'other');
    expect(s.feedRank, 3);
    expect(s.durationMs, 21000);
    expect(s.thumbUrl('c'), 'c/thumbs/statuses/amman/x.jpg');
  });
}
