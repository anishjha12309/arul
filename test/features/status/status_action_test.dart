// Share prepares, then the user picks a target; each target falls through to the next only on false.
// Status clips go out CLEAN: neither verb ever calls the watermark service.
// The gate is read on EVERY action, cached bytes or not; a 403 routes to the paywall, never a crash.
import 'dart:async';
import 'dart:io';

import 'package:arul/app/l10n/app_localizations.dart';
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
  final downloads = <String>[];
  final saved = <String>[];
  final savedFrom = <String>[];

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
    downloads.add(url);
    onProgress(1);
    return File(outPath)..writeAsBytesSync(List.filled(32, 7));
  }

  @override
  Future<StatusSaveResult> saveToGallery(
    String filePath,
    String displayName,
  ) async {
    savedFrom.add(filePath);
    saved.add(displayName);
    return save ?? (outcome: StatusSaveOutcome.saved, reason: null);
  }
}

class _FakeDirectShare implements DirectShareService {
  _FakeDirectShare({
    this.installed = true,
    this.composer = false,
    this.sendToStatusAction = false,
    this.picker = false,
    this.hold,
  });

  // When set, the picker call parks on it -> a test can look at the state mid-hand-off.
  final Future<void>? hold;
  final bool installed;
  final bool composer;
  final bool sendToStatusAction;
  final bool picker;
  final calls = <String>[];
  String? caption;

  @override
  Future<bool> hasWhatsApp({required String mimeType}) async => installed;

  @override
  Future<bool> shareToStatus({required String filePath}) async {
    calls.add('composer');
    return composer;
  }

  @override
  Future<bool> sendToStatus({
    required String filePath,
    required String mimeType,
  }) async {
    calls.add('send_to_status');
    return sendToStatusAction;
  }

  @override
  Future<bool> shareToWhatsApp({
    required String filePath,
    required String mimeType,
    required String text,
  }) async {
    calls.add('picker');
    caption = text;
    if (hold != null) await hold;
    return picker;
  }

  @override
  Future<bool> shareTextToWhatsApp(String text) async => false;
}

/// Status never watermarks -> every method here records, and the suite asserts it stayed empty.
class _FakeWatermark implements ShareWatermarkService {
  final calls = <String>[];

  @override
  WatermarkSpec plan({required String wallpaperId, String? userId}) {
    calls.add('plan');
    return const WatermarkSpec(logoCorner: 0, code: 'AR-TEST01');
  }

  @override
  Future<({bool supported, int sdkInt})> videoWatermarkSupport() async {
    calls.add('support');
    return (supported: true, sdkInt: 34);
  }

  @override
  Future<File> watermarkVideo(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    calls.add('video');
    return File(outPath)..writeAsBytesSync(List.filled(16, 9));
  }

  @override
  Future<File> watermarkImage(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    calls.add('image');
    return File(outPath);
  }

  @override
  Future<Uint8List> renderOverlayPng(
    WatermarkSpec spec, {
    required int width,
    required int height,
  }) async {
    calls.add('overlay');
    return Uint8List(0);
  }
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
  late _FakeWatermark watermark;
  late List<StatusActionState> stateAtSheet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('status_action_test');
    analytics = _RecordingAnalytics();
    sheet = [];
    watermark = _FakeWatermark();
    stateAtSheet = [];
    addTearDown(() => tmp.deleteSync(recursive: true));
  });

  ProviderContainer? current;

  ProviderContainer container({
    required _FakeMedia media,
    _FakeDirectShare? direct,
  }) {
    final c = ProviderContainer(
      overrides: [
        statusTempDirProvider.overrideWith((_) async => tmp),
        statusMediaServiceProvider.overrideWithValue(media),
        statusPrefetchServiceProvider.overrideWithValue(_NoPrefetch()),
        directShareServiceProvider.overrideWithValue(
          direct ?? _FakeDirectShare(),
        ),
        shareWatermarkServiceProvider.overrideWithValue(watermark),
        localeProvider.overrideWith(_FixedLocale.new),
        analyticsServiceProvider.overrideWithValue(analytics),
        authStateStreamProvider.overrideWith(
          (ref) => Stream.value(AuthUserState.unauthenticated()),
        ),
        shareSheetLauncherProvider.overrideWithValue((params) async {
          stateAtSheet.add(current!.read(statusActionProvider));
          sheet.add(params);
          return const ShareResult('app', ShareResultStatus.success);
        }),
      ],
    );
    addTearDown(c.dispose);
    return current = c;
  }

  /// Prepare, then pick [target] — the screen's two calls with the sheet in between.
  Future<StatusActionOutcome?> shareTo(
    ProviderContainer c,
    StatusShareTarget target, {
    String Function(String link)? caption,
  }) async {
    final actions = c.read(statusActionProvider.notifier);
    expect(await actions.prepareShare(_clip), isA<StatusShareReady>());
    return actions.shareVia(
      target,
      buildCaption: caption ?? (link) => 'cap\n$link',
    );
  }

  const link =
      'https://arul.hsrutility.com/s/c0ffee00-1c2d-4f3a-9b8e-7d6c5a4b3e2f'
      '?ilang=ta';

  group('prepare', () {
    test(
      'gates, fetches and asks; WhatsApp present -> ready for the sheet',
      () async {
        final media = _FakeMedia();
        final c = container(media: media);
        final stages = <StatusActionState>[];
        c.listen(statusActionProvider, (_, s) => stages.add(s));

        final prep = await c
            .read(statusActionProvider.notifier)
            .prepareShare(_clip);

        expect(prep, isA<StatusShareReady>());
        expect((prep! as StatusShareReady).whatsApp, isTrue);
        expect(media.grants, [StatusMediaAction.share]);
        expect(c.read(statusActionProvider), isA<StatusActionChoosing>());
        // The card's line follows the real stages: fetching (with the download's progress), then preparing.
        final busy = stages.whereType<StatusActionBusy>().toList();
        expect(busy.first.stage, StatusActionStage.fetching);
        expect(busy.any((s) => s.progress == 1), isTrue);
        expect(busy.last.stage, StatusActionStage.preparing);
        expect(watermark.calls, isEmpty);
        expect(analytics.events, isEmpty, reason: 'nothing has left yet');
      },
    );

    test('no WhatsApp at all -> ready, but not for the Arul sheet', () async {
      final c = container(
        media: _FakeMedia(),
        direct: _FakeDirectShare(installed: false),
      );

      final prep = await c
          .read(statusActionProvider.notifier)
          .prepareShare(_clip);

      expect((prep! as StatusShareReady).whatsApp, isFalse);
    });

    test('a server 403 is a paywall outcome, and nothing leaves', () async {
      final direct = _FakeDirectShare(composer: true);
      final c = container(
        media: _FakeMedia(premiumRequired: true),
        direct: direct,
      );

      final prep = await c
          .read(statusActionProvider.notifier)
          .prepareShare(_clip);

      expect(
        (prep! as StatusShareSettled).outcome,
        StatusActionOutcome.premiumRequired,
      );
      expect(direct.calls, isEmpty);
      expect(analytics.events, isNot(contains('status_shared')));
      expect(c.read(statusActionProvider), isA<StatusActionIdle>());
    });

    test('cached bytes skip the download but never the gate', () async {
      final media = _FakeMedia();
      final c = container(media: media);
      File('${tmp.path}/status-${_clip.id}.mp4').writeAsBytesSync([1, 2, 3]);

      await c.read(statusActionProvider.notifier).prepareShare(_clip);

      expect(media.grants, [StatusMediaAction.share]);
      expect(media.downloads, isEmpty);
    });
  });

  group('targets', () {
    test('Status: the composer first, no caption, no link', () async {
      final direct = _FakeDirectShare(composer: true);
      final c = container(media: _FakeMedia(), direct: direct);

      final outcome = await shareTo(c, StatusShareTarget.status);

      expect(outcome, StatusActionOutcome.done);
      expect(direct.calls, ['composer']);
      expect(direct.caption, isNull);
      expect(sheet, isEmpty);
      expect(analytics.props['status_shared'], {
        'status_id': _clip.id,
        'category': 'murugan',
        'result': 'unavailable',
        'watermarked': false,
        'channel': 'status',
        'via': 'composer',
        'has_whatsapp': true,
      });
      expect(c.read(statusActionProvider), isA<StatusActionIdle>());
    });

    test('Status: no composer -> SEND_TO_STATUS, still no caption', () async {
      final direct = _FakeDirectShare(sendToStatusAction: true);
      final c = container(media: _FakeMedia(), direct: direct);

      await shareTo(c, StatusShareTarget.status);

      expect(direct.calls, ['composer', 'send_to_status']);
      expect(direct.caption, isNull);
      expect(analytics.props['status_shared']?['via'], 'send_to_status');
      expect(analytics.props['status_shared']?['channel'], 'status');
    });

    test('Status: neither surface -> the picker, carrying ONE link', () async {
      final direct = _FakeDirectShare(picker: true);
      final c = container(media: _FakeMedia(), direct: direct);

      await shareTo(c, StatusShareTarget.status);

      expect(direct.calls, ['composer', 'send_to_status', 'picker']);
      expect(direct.caption, 'cap\n$link');
      expect(analytics.props['status_shared']?['via'], 'picker');
    });

    for (final (target, channel) in [
      (StatusShareTarget.groups, 'groups'),
      (StatusShareTarget.chat, 'chat'),
    ]) {
      test(
        '${target.name}: the picker with ONE trailing link, channel=$channel',
        () async {
          final direct = _FakeDirectShare(picker: true);
          final c = container(media: _FakeMedia(), direct: direct);

          await shareTo(c, target);

          expect(direct.calls, ['picker'], reason: 'never a status surface');
          expect(direct.caption, 'cap\n$link');
          expect(RegExp('https://').allMatches(direct.caption!), hasLength(1));
          expect(sheet, isEmpty);
          expect(analytics.props['status_shared']?['channel'], channel);
          expect(analytics.props['status_shared']?['via'], 'picker');
        },
      );

      test(
        '${target.name}: a refused picker falls to the system sheet',
        () async {
          final direct = _FakeDirectShare();
          final c = container(media: _FakeMedia(), direct: direct);

          await shareTo(c, target);

          expect(direct.calls, ['picker']);
          expect(sheet.single.text, 'cap\n$link');
          expect(analytics.props['status_shared']?['channel'], channel);
          expect(analytics.props['status_shared']?['via'], 'sheet');
          expect(analytics.props['status_shared']?['result'], 'success');
        },
      );
    }

    test(
      'Status all the way down: every surface refused -> the sheet',
      () async {
        final direct = _FakeDirectShare();
        final c = container(media: _FakeMedia(), direct: direct);

        await shareTo(c, StatusShareTarget.status);

        expect(direct.calls, ['composer', 'send_to_status', 'picker']);
        expect(sheet.single.text, 'cap\n$link');
        expect(analytics.props['status_shared']?['via'], 'sheet');
      },
    );

    test(
      'More: the system sheet only, the clip plus ONE trailing link',
      () async {
        final direct = _FakeDirectShare(composer: true, picker: true);
        final c = container(media: _FakeMedia(), direct: direct);

        await shareTo(c, StatusShareTarget.more);

        expect(direct.calls, isEmpty, reason: 'More never targets WhatsApp');
        final params = sheet.single;
        expect(params.files?.single.mimeType, 'video/mp4');
        expect(params.fileNameOverrides, ['arul-murugan-vel.mp4']);
        expect(params.text, 'cap\n$link');
        expect(analytics.props['status_shared']?['channel'], 'sheet');
        expect(analytics.props['status_shared']?['via'], 'sheet');
      },
    );

    test(
      'the shared file IS the fetched clip, never a re-encoded copy',
      () async {
        final c = container(media: _FakeMedia());

        await shareTo(c, StatusShareTarget.more);

        expect(
          sheet.single.files?.single.path,
          '${tmp.path}/status-${_clip.id}.mp4',
        );
        expect(watermark.calls, isEmpty);
        expect(analytics.props['status_shared']?['watermarked'], false);
      },
    );
  });

  group('re-entrancy and dismissal', () {
    test('a closed sheet shares nothing and tracks nothing', () async {
      final direct = _FakeDirectShare(composer: true, picker: true);
      final c = container(media: _FakeMedia(), direct: direct);
      final actions = c.read(statusActionProvider.notifier);
      await actions.prepareShare(_clip);

      actions.dismissShare();

      expect(c.read(statusActionProvider), isA<StatusActionIdle>());
      expect(
        await actions.shareVia(StatusShareTarget.chat, buildCaption: (l) => l),
        isNull,
        reason: 'nothing is prepared any more',
      );
      expect(direct.calls, isEmpty);
      expect(sheet, isEmpty);
      expect(analytics.events, isNot(contains('status_shared')));
    });

    test('a second tap while one action runs or waits is refused', () async {
      final media = _FakeMedia();
      final c = container(media: media);
      final actions = c.read(statusActionProvider.notifier);

      final first = actions.prepareShare(_clip);
      expect(await actions.prepareShare(_clip), isNull, reason: 'fetching');
      expect(await actions.save(_clip), isNull, reason: 'fetching');
      await first;
      expect(await actions.prepareShare(_clip), isNull, reason: 'choosing');
      expect(await actions.save(_clip), isNull, reason: 'choosing');
      expect(media.grants, [StatusMediaAction.share], reason: 'one gate read');
    });

    test('the guard holds while WhatsApp opens, and lifts after', () async {
      final hold = Completer<void>();
      final direct = _FakeDirectShare(picker: true, hold: hold.future);
      final c = container(media: _FakeMedia(), direct: direct);
      final actions = c.read(statusActionProvider.notifier);
      await actions.prepareShare(_clip);

      final sending = actions.shareVia(
        StatusShareTarget.groups,
        buildCaption: (l) => l,
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.read(statusActionProvider), isA<StatusActionSending>());
      expect(await actions.prepareShare(_clip), isNull);
      expect(await actions.save(_clip), isNull);

      hold.complete();
      expect(await sending, StatusActionOutcome.done);
      expect(c.read(statusActionProvider), isA<StatusActionIdle>());
    });

    test('the system sheet opens with the pills already live', () async {
      final c = container(
        media: _FakeMedia(),
        direct: _FakeDirectShare(installed: false),
      );

      await shareTo(c, StatusShareTarget.more);

      // share_plus resolves only when its sheet CLOSES -> idle must come first.
      expect(stateAtSheet.single, isA<StatusActionIdle>());
      expect(analytics.props['status_shared']?['has_whatsapp'], false);
    });

    test(
      'a pick fires once: the second shareVia finds nothing prepared',
      () async {
        final direct = _FakeDirectShare(picker: true);
        final c = container(media: _FakeMedia(), direct: direct);
        final actions = c.read(statusActionProvider.notifier);
        await actions.prepareShare(_clip);

        final a = actions.shareVia(
          StatusShareTarget.chat,
          buildCaption: (l) => l,
        );
        final b = actions.shareVia(
          StatusShareTarget.chat,
          buildCaption: (l) => l,
        );

        expect(await a, StatusActionOutcome.done);
        expect(await b, isNull);
        expect(direct.calls, ['picker']);
        expect(
          analytics.events.where((e) => e == 'status_shared'),
          hasLength(1),
        );
      },
    );
  });

  group('the caption contract, in every shipped language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      test(
        '${locale.languageCode}: ONE link, alone on the last line',
        () async {
          final l10n = lookupAppLocalizations(locale);
          final direct = _FakeDirectShare(picker: true);
          final c = container(media: _FakeMedia(), direct: direct);

          await shareTo(
            c,
            StatusShareTarget.groups,
            caption: l10n.statusShareCaption,
          );
          await shareTo(
            c,
            StatusShareTarget.more,
            caption: l10n.statusShareCaption,
          );

          for (final text in [direct.caption!, sheet.single.text!]) {
            expect(RegExp('https?://').allMatches(text), hasLength(1));
            expect(text.trimRight().split('\n').last, link);
          }
        },
      );
    }
  });

  group('Save', () {
    test('saves the fetched clip byte for byte under a fresh name', () async {
      final media = _FakeMedia();
      final c = container(media: media);
      final stages = <StatusActionState>[];
      c.listen(statusActionProvider, (_, s) => stages.add(s));

      final outcome = await c.read(statusActionProvider.notifier).save(_clip);

      expect(outcome, StatusActionOutcome.done);
      expect(media.grants, [StatusMediaAction.download]);
      expect(media.savedFrom.single, '${tmp.path}/status-${_clip.id}.mp4');
      expect(media.saved.single, startsWith('arul-murugan-vel-'));
      expect(media.saved.single, endsWith('.mp4'));
      expect(watermark.calls, isEmpty);
      expect(
        stages.whereType<StatusActionBusy>().last.stage,
        StatusActionStage.saving,
      );
      expect(analytics.props['status_saved'], {
        'status_id': _clip.id,
        'category': 'murugan',
        'watermarked': false,
      });
    });

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
