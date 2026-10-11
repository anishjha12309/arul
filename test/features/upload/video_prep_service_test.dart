// VideoPrepService against a scripted native side: the channel contract (method names, argument
// keys, error codes) only matches at runtime, so these pin it from the Dart end.

import 'dart:async';
import 'dart:io';

import 'package:arul/features/upload/data/video_prep_service.dart';
import 'package:arul/features/upload/domain/video_plan.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _mb = 1024 * 1024;
const _input = '/picks/123/clip.mp4';

Map<String, Object?> _facts({
  int width = 1080,
  int height = 1920,
  int rotation = 0,
  int durationMs = 20000,
  bool hasAudio = true,
  String? videoMime = 'video/avc',
  String? containerMime = 'video/mp4',
  int bytes = 6 * _mb,
  bool exportSupported = true,
}) => {
  'width': width,
  'height': height,
  'rotation': rotation,
  'durationMs': durationMs,
  'hasAudio': hasAudio,
  'videoMime': videoMime,
  'containerMime': containerMime,
  'bytes': bytes,
  'exportSupported': exportSupported,
};

/// The status output a 1080x1920 source should come back as.
Map<String, Object?> _statusOutput({int bytes = 8 * _mb, int width = 1024}) =>
    _facts(width: width, height: 1824, bytes: bytes);

Map<String, Object?> _live({required int bytes}) => _facts(
  width: 1024,
  height: 1824,
  bytes: bytes,
  durationMs: 8000,
  hasAudio: false,
);

Matcher _fails(VideoPrepFailure failure) => throwsA(
  isA<VideoPrepException>().having((e) => e.failure, 'failure', failure),
);

/// An export outcome that writes the file but leaves it unprobeable.
const _unprobeable = 'unprobeable';

/// Plays VideoPrepChannel: answers probes from [probes], and each export takes the next of
/// [exports] (the output's probe facts, [_unprobeable], or a PlatformException to throw).
class _FakeNative {
  final calls = <MethodCall>[];
  final probes = <String, Map<String, Object?>>{};
  final exports = <Object>[];
  final progressDuringExport = <int>[];
  MockStreamHandlerEventSink? sink;

  /// Holds every export until completed, so a test can look at it mid-flight.
  Completer<void>? exportGate;

  /// Holds every probe until completed.
  Completer<void>? probeGate;

  /// Leaves the export pending until a `cancel` arrives, as the native side does.
  bool holdExportUntilCancel = false;
  Completer<Object?>? _pendingExport;

  List<String> get methods => [for (final c in calls) c.method];

  List<Map<Object?, Object?>> get exportArgs => [
    for (final c in calls)
      if (c.method == 'export') c.arguments as Map<Object?, Object?>,
  ];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments as Map<Object?, Object?>?;
    switch (call.method) {
      case 'probe':
        await probeGate?.future;
        final facts = probes[args?['path']];
        if (facts == null) {
          throw PlatformException(code: 'probe_failed', message: 'unreadable');
        }
        return facts;
      case 'export':
        for (final percent in progressDuringExport) {
          sink?.success(percent);
        }
        await exportGate?.future;
        if (holdExportUntilCancel) {
          return (_pendingExport = Completer<Object?>()).future;
        }
        final outcome = exports.removeAt(0);
        if (outcome is PlatformException) throw outcome;
        final output = args?['outputPath'] as String? ?? '';
        File(output).createSync(recursive: true);
        if (outcome is Map<String, Object?>) probes[output] = outcome;
        return {'path': output, 'bytes': 1};
      case 'cancel':
        _pendingExport?.completeError(
          PlatformException(code: 'cancelled', message: 'export cancelled'),
        );
        _pendingExport = null;
        return null;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('test/video_prep');
  const progress = EventChannel('test/video_prep/progress');

  late Directory cache;
  late _FakeNative native;

  VideoPrepService service() => VideoPrepService(
    channel: channel,
    progressChannel: progress,
    cacheDirectory: () async => cache,
  );

  setUp(() {
    cache = Directory.systemTemp.createTempSync('video_prep_test');
    native = _FakeNative();
    messenger.setMockMethodCallHandler(channel, native.handle);
    messenger.setMockStreamHandler(
      progress,
      MockStreamHandler.inline(
        onListen: (arguments, events) => native.sink = events,
        onCancel: (arguments) => native.sink = null,
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test('no native side: the clip goes up as picked', () async {
    final file = File('${cache.path}/clip.mp4')
      ..writeAsBytesSync(List.filled(1234, 0));
    final prepared = await VideoPrepService(
      channel: const MethodChannel('test/video_prep_absent'),
      progressChannel: progress,
      cacheDirectory: () async => cache,
    ).prepare(file.path, VideoTarget.status);

    expect(prepared.path, file.path);
    expect(prepared.converted, isFalse);
    expect(prepared.bytes, 1234);
    expect(prepared.width, 0);
  });

  test('a compliant clip passes through with no export', () async {
    native.probes[_input] = _facts(width: 1024, height: 1536, bytes: 7 * _mb);

    final prepared = await service().prepare(_input, VideoTarget.status);

    expect(prepared.path, _input);
    expect(prepared.converted, isFalse);
    expect((prepared.width, prepared.height), (1024, 1536));
    expect(prepared.bytes, 7 * _mb);
    expect(native.methods, ['probe']);
  });

  test(
    'a camera clip is exported to the plan, with progress, and re-probed',
    () async {
      native.probes[_input] = _facts(durationMs: 45000);
      native.exports.add(_statusOutput());
      native.progressDuringExport.addAll([25, 50]);
      final gate = native.exportGate = Completer<void>();
      final seen = <double>[];

      final future = service().prepare(
        _input,
        VideoTarget.status,
        onProgress: seen.add,
      );
      await pumpEventQueue();
      expect(seen, [0.25, 0.5]);
      gate.complete();
      final prepared = await future;

      expect(native.methods, ['probe', 'export', 'probe']);
      final args = native.exportArgs.single;
      expect(args['inputPath'], _input);
      expect(args['width'], 1024);
      expect(args['height'], 1824);
      expect(args['endMs'], 29800);
      expect(args['removeAudio'], false);
      expect(args['videoBitrate'], 2000000);
      expect(args['audioBitrate'], 128000);
      final output = args['outputPath']! as String;
      expect(output, startsWith('${cache.path}/upload_prepared/'));
      expect(output, endsWith('/clip.mp4'));

      expect(prepared.path, output);
      expect(prepared.converted, isTrue);
      expect((prepared.width, prepared.height), (1024, 1824));
      expect(prepared.bytes, 8 * _mb);
      expect(seen.last, 1.0);
      expect(native.sink, isNull, reason: 'the progress stream is let go');
    },
  );

  test(
    'a live wallpaper export drops the audio and sends no audio bitrate',
    () async {
      native.probes[_input] = _facts(durationMs: 8000);
      native.exports.add(
        _facts(width: 1024, height: 1824, hasAudio: false, durationMs: 8000),
      );

      final prepared = await service().prepare(
        _input,
        VideoTarget.liveWallpaper,
      );

      final args = native.exportArgs.single;
      expect(args['removeAudio'], true);
      expect(args['audioBitrate'], isNull);
      expect(args['videoBitrate'], 8000000);
      expect(args['endMs'], isNull);
      expect(prepared.converted, isTrue);
    },
  );

  test(
    'a status output over 10 MB is retried once, smaller and at 1.5 Mbps',
    () async {
      native.probes[_input] = _facts();
      // 11 MB at 1024x1824 -> aim for 85% of the cap -> 896 wide, the source's aspect kept.
      native.exports
        ..add(_statusOutput(bytes: 11 * _mb))
        ..add(_facts(width: 896, height: 1600, bytes: 8 * _mb));

      final prepared = await service().prepare(_input, VideoTarget.status);

      final args = native.exportArgs;
      expect(args, hasLength(2));
      expect(args[0]['videoBitrate'], 2000000);
      expect((args[0]['width'], args[0]['height']), (1024, 1824));
      // A MediaTek encoder ignores the bitrate (A001) but obeys the size -> the retry shrinks.
      expect(args[1]['videoBitrate'], 1500000);
      expect((args[1]['width'], args[1]['height']), (896, 1600));
      final first = args[0]['outputPath']! as String;
      final second = args[1]['outputPath']! as String;
      expect(
        File(first).parent.existsSync(),
        isFalse,
        reason: 'oversize deleted',
      );
      expect(File(second).parent.path, isNot(File(first).parent.path));
      expect(prepared.path, second);
      expect(prepared.bytes, 8 * _mb);
    },
  );

  test(
    'a live output over its cap keeps 1024x1824 and only drops the bitrate',
    () async {
      native.probes[_input] = _facts(durationMs: 8000);
      native.exports
        ..add(_live(bytes: 16 * _mb))
        ..add(_live(bytes: 9 * _mb));

      await service().prepare(_input, VideoTarget.liveWallpaper);

      final args = native.exportArgs;
      expect(args, hasLength(2));
      expect((args[1]['width'], args[1]['height']), (1024, 1824));
      expect(args[1]['videoBitrate'], 6000000);
    },
  );

  test(
    'still over the cap after the retry fails as tooLarge, nothing left behind',
    () async {
      native.probes[_input] = _facts();
      // The retry asks for 768x1376 (12 MB aimed at 85% of the cap) and still lands over it.
      native.exports
        ..add(_statusOutput(bytes: 12 * _mb))
        ..add(_facts(width: 768, height: 1376, bytes: 11 * _mb));

      await expectLater(
        service().prepare(_input, VideoTarget.status),
        _fails(VideoPrepFailure.tooLarge),
      );
      expect(native.exportArgs, hasLength(2));
      for (final args in native.exportArgs) {
        expect(File(args['outputPath']! as String).existsSync(), isFalse);
      }
    },
  );

  group('failures', () {
    test('a probe the native side cannot read is unreadable', () async {
      await expectLater(
        service().prepare('/picks/missing.mp4', VideoTarget.status),
        _fails(VideoPrepFailure.unreadable),
      );
    });

    test('a status without audio is noAudio, before any export', () async {
      native.probes[_input] = _facts(hasAudio: false);
      await expectLater(
        service().prepare(_input, VideoTarget.status),
        _fails(VideoPrepFailure.noAudio),
      );
      expect(native.methods, ['probe']);
    });

    test(
      'a clip that needs converting below API 31 is unsupportedDevice',
      () async {
        native.probes[_input] = _facts(exportSupported: false);
        await expectLater(
          service().prepare(_input, VideoTarget.status),
          _fails(VideoPrepFailure.unsupportedDevice),
        );
        expect(native.methods, ['probe']);
      },
    );

    for (final (code, failure) in [
      ('unsupported_api', VideoPrepFailure.unsupportedDevice),
      ('busy', VideoPrepFailure.busy),
      ('bad_input', VideoPrepFailure.unreadable),
      ('cancelled', VideoPrepFailure.cancelled),
      ('transform_failed', VideoPrepFailure.exportFailed),
    ]) {
      test('export error $code -> ${failure.name}', () async {
        native.probes[_input] = _facts();
        native.exports.add(PlatformException(code: code, message: 'x'));
        await expectLater(
          service().prepare(_input, VideoTarget.status),
          _fails(failure),
        );
      });
    }

    test('an output off the plan is exportFailed and deleted', () async {
      native.probes[_input] = _facts();
      native.exports.add(_statusOutput(width: 1088));

      await expectLater(
        service().prepare(_input, VideoTarget.status),
        _fails(VideoPrepFailure.exportFailed),
      );
      final output = native.exportArgs.single['outputPath']! as String;
      expect(File(output).existsSync(), isFalse);
    });

    test(
      'an output that cannot be probed is exportFailed and deleted',
      () async {
        native.probes[_input] = _facts();
        native.exports.add(_unprobeable);

        await expectLater(
          service().prepare(_input, VideoTarget.status),
          _fails(VideoPrepFailure.exportFailed),
        );
        final output = native.exportArgs.single['outputPath']! as String;
        expect(File(output).existsSync(), isFalse);
      },
    );
  });

  group('cancel', () {
    test(
      'mid-export: the native export is cancelled and prepare says so',
      () async {
        native.probes[_input] = _facts();
        native.holdExportUntilCancel = true;
        final prep = service();

        final future = prep.prepare(_input, VideoTarget.status);
        await pumpEventQueue();
        expect(native.methods, ['probe', 'export']);
        await prep.cancel();

        await expectLater(future, _fails(VideoPrepFailure.cancelled));
        expect(native.methods, ['probe', 'export', 'cancel']);
      },
    );

    test('before the export starts: no export is ever sent', () async {
      native.probes[_input] = _facts();
      final gate = native.probeGate = Completer<void>();
      final prep = service();

      final future = prep.prepare(_input, VideoTarget.status);
      await pumpEventQueue();
      await prep.cancel();
      gate.complete();

      await expectLater(future, _fails(VideoPrepFailure.cancelled));
      expect(native.methods, isNot(contains('export')));
    });

    test('with nothing in flight it does not call the native side', () async {
      await service().cancel();
      expect(native.methods, isEmpty);
    });
  });
}
