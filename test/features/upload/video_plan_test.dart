// planVideo is the whole decision between "upload as picked" and "convert on the phone", and the
// sizes it picks must pass the Worker's byte QC (media-verify.ts), so every case asserts exact numbers.

import 'package:arul/features/upload/domain/video_plan.dart';
import 'package:flutter_test/flutter_test.dart';

const _mb = 1024 * 1024;

VideoProbe _probe({
  int width = 1080,
  int height = 1920,
  int durationMs = 20000,
  bool hasAudio = true,
  String? videoMime = 'video/avc',
  int bytes = 6 * _mb,
  int rotationDegrees = 0,
  bool isMp4 = true,
  bool exportSupported = true,
}) => VideoProbe(
  width: width,
  height: height,
  durationMs: durationMs,
  hasAudio: hasAudio,
  videoMime: videoMime,
  bytes: bytes,
  rotationDegrees: rotationDegrees,
  isMp4: isMp4,
  exportSupported: exportSupported,
);

/// The status export a source of [width]x[height] gets, as `WxH`.
String _statusSize(int width, int height) {
  final plan = planVideo(
    _probe(width: width, height: height, bytes: 40 * _mb),
    VideoTarget.status,
  );
  expect(plan, isA<ExportPlan>());
  final export = plan as ExportPlan;
  expect(
    VideoRule.fits(export.width, export.height),
    isTrue,
    reason: 'off the video rule',
  );
  return '${export.width}x${export.height}';
}

void main() {
  group('VideoRule mirrors onVideoRule', () {
    test('accepts the canonical shapes in either orientation', () {
      expect(VideoRule.fits(1024, 1824), isTrue);
      expect(VideoRule.fits(1024, 1536), isTrue);
      expect(VideoRule.fits(1920, 1088), isTrue);
      expect(VideoRule.fits(1024, 576), isTrue);
    });

    test(
      'rejects a camera size, an unaligned side and anything past the caps',
      () {
        expect(VideoRule.fits(1080, 1920), isFalse);
        expect(VideoRule.fits(720, 1280), isFalse);
        expect(
          VideoRule.fits(1088, 1920),
          isFalse,
          reason: '1088 is not 128-aligned',
        );
        expect(
          VideoRule.fits(1024, 1952),
          isFalse,
          reason: 'long side over 1920',
        );
        expect(
          VideoRule.fits(1152, 1536),
          isFalse,
          reason: 'short side over 1088',
        );
        expect(VideoRule.fits(0, 1824), isFalse);
      },
    );
  });

  group('status keeps the source shape, largest on the rule, never upscaled', () {
    test('1080x1920 -> 1024x1824 (the doc 9:16 shape)', () {
      expect(_statusSize(1080, 1920), '1024x1824');
    });

    test('720x1280 -> 640x1152, not upscaled to 1024 wide', () {
      expect(_statusSize(720, 1280), '640x1152');
    });

    test(
      '1080x2400 -> 768x1696: at 1024 wide it would run past the 1920 cap',
      () {
        expect(_statusSize(1080, 2400), '768x1696');
      },
    );

    test('2160x3840 -> 1024x1824', () {
      expect(_statusSize(2160, 3840), '1024x1824');
    });

    test('480x854 -> 384x672', () {
      expect(_statusSize(480, 854), '384x672');
    });

    test(
      'landscape 1920x1080 -> 1792x1024, never padded to a portrait canvas',
      () {
        expect(_statusSize(1920, 1080), '1792x1024');
      },
    );

    test('a 2:3 source lands on the server example 1024x1536', () {
      expect(_statusSize(1080, 1620), '1024x1536');
    });

    test('every pick stays within 2% of the source aspect', () {
      for (final (w, h) in [
        (1080, 1920),
        (720, 1280),
        (1080, 2400),
        (480, 854),
        (1920, 1080),
        (1280, 720),
        (3840, 2160),
        (1080, 1080),
      ]) {
        final size = ruleSizeFor(w, h);
        final error = ((size.width / size.height) / (w / h) - 1).abs();
        expect(error, lessThanOrEqualTo(0.02), reason: '$w x $h -> $size');
        expect(size.width, lessThanOrEqualTo(w), reason: 'upscaled $w x $h');
        expect(size.height, lessThanOrEqualTo(h), reason: 'upscaled $w x $h');
      }
    });

    test('a source too small for the rule takes the least upscale', () {
      expect(ruleSizeFor(480, 270), (width: 512, height: 288));
      expect(ruleSizeFor(100, 100), (width: 128, height: 128));
    });

    test('an aspect no rule size reaches within 2% takes the closest one', () {
      expect(ruleSizeFor(100, 2000), (width: 128, height: 1920));
    });

    test('a rotated source is planned on its DISPLAY size', () {
      // Stored 1920x1080 turned 90 degrees: the probe already reports 1080x1920.
      final plan = planVideo(
        _probe(rotationDegrees: 90, bytes: 40 * _mb),
        VideoTarget.status,
      );
      expect(
        plan,
        const ExportPlan(
          width: 1024,
          height: 1824,
          removeAudio: false,
          videoBitrate: 2000000,
          audioBitrate: 128000,
        ),
      );
    });
  });

  group('planVideo for a status', () {
    test('an already compliant clip passes through untouched', () {
      final plan = planVideo(
        _probe(width: 1024, height: 1536, durationMs: 29000, bytes: 9 * _mb),
        VideoTarget.status,
      );
      expect(plan, const PassThroughPlan());
    });

    test('a long clip is cut at 29.8 s with the doc recipe bitrates', () {
      final plan = planVideo(_probe(durationMs: 45000), VideoTarget.status);
      expect(
        plan,
        const ExportPlan(
          width: 1024,
          height: 1824,
          removeAudio: false,
          videoBitrate: 2000000,
          endMs: 29800,
          audioBitrate: 128000,
        ),
      );
    });

    test(
      'a clip just under 30 s that needs converting is still cut at 29.8 s',
      () {
        final plan = planVideo(_probe(durationMs: 29950), VideoTarget.status);
        expect((plan as ExportPlan).endMs, 29800);
      },
    );

    test('a short clip keeps its whole length', () {
      final plan = planVideo(_probe(durationMs: 12000), VideoTarget.status);
      expect((plan as ExportPlan).endMs, isNull);
    });

    test('no audio track fails as noAudio, with nothing exported', () {
      expect(
        planVideo(_probe(hasAudio: false), VideoTarget.status),
        const RejectPlan(VideoPrepFailure.noAudio),
      );
      expect(
        planVideo(
          _probe(hasAudio: false, exportSupported: false),
          VideoTarget.status,
        ),
        const RejectPlan(VideoPrepFailure.noAudio),
        reason: 'the actionable reason wins over the device one',
      );
    });

    test('a compliant shape over 10 MB is re-encoded at the same size', () {
      final plan = planVideo(
        _probe(width: 1024, height: 1536, bytes: 11 * _mb),
        VideoTarget.status,
      );
      expect(plan, isA<ExportPlan>());
      final export = plan as ExportPlan;
      expect((export.width, export.height), (1024, 1536));
    });

    test('a compliant clip over 30 s is converted, not passed', () {
      final plan = planVideo(
        _probe(width: 1024, height: 1536, durationMs: 30100),
        VideoTarget.status,
      );
      expect((plan as ExportPlan).endMs, 29800);
    });

    test('HEVC, a turned stored frame or a non-.mp4 name is converted', () {
      for (final probe in [
        _probe(width: 1024, height: 1536, videoMime: 'video/hevc'),
        _probe(width: 1024, height: 1824, rotationDegrees: 90),
        _probe(width: 1024, height: 1536, isMp4: false),
      ]) {
        expect(planVideo(probe, VideoTarget.status), isA<ExportPlan>());
      }
    });

    test(
      'below API 31 a clip that needs converting fails as unsupportedDevice',
      () {
        expect(
          planVideo(_probe(exportSupported: false), VideoTarget.status),
          const RejectPlan(VideoPrepFailure.unsupportedDevice),
        );
      },
    );

    test('below API 31 a compliant clip still passes through', () {
      expect(
        planVideo(
          _probe(width: 1024, height: 1536, exportSupported: false),
          VideoTarget.status,
        ),
        const PassThroughPlan(),
      );
    });

    test('a file with no video track or no duration is unreadable', () {
      for (final probe in [
        _probe(videoMime: null),
        _probe(width: 0, height: 0),
        _probe(durationMs: 0),
      ]) {
        expect(
          planVideo(probe, VideoTarget.status),
          const RejectPlan(VideoPrepFailure.unreadable),
        );
      }
    });
  });

  group('planVideo for a live wallpaper', () {
    const live = ExportPlan(
      width: 1024,
      height: 1824,
      removeAudio: true,
      videoBitrate: 8000000,
    );

    test('a 9:16 source becomes exactly 1024x1824, muted', () {
      expect(
        planVideo(_probe(durationMs: 8000), VideoTarget.liveWallpaper),
        live,
      );
    });

    test('a landscape source is cropped into 1024x1824', () {
      expect(
        planVideo(
          _probe(width: 1920, height: 1080, durationMs: 6000),
          VideoTarget.liveWallpaper,
        ),
        live,
      );
    });

    test('a long source is cut at 10 s', () {
      final plan = planVideo(
        _probe(durationMs: 25000),
        VideoTarget.liveWallpaper,
      );
      expect((plan as ExportPlan).endMs, 10000);
    });

    test('a silent source is fine: a live wallpaper never needs audio', () {
      expect(
        planVideo(
          _probe(hasAudio: false, durationMs: 8000),
          VideoTarget.liveWallpaper,
        ),
        live,
      );
    });

    test('an already canonical muted clip passes through', () {
      expect(
        planVideo(
          _probe(width: 1024, height: 1824, hasAudio: false, durationMs: 9000),
          VideoTarget.liveWallpaper,
        ),
        const PassThroughPlan(),
      );
    });

    test('a canonical clip that carries audio is re-encoded without it', () {
      final plan = planVideo(
        _probe(width: 1024, height: 1824, durationMs: 9000),
        VideoTarget.liveWallpaper,
      );
      expect(plan, live);
    });

    test('another size on the video rule is still not the live canvas', () {
      final plan = planVideo(
        _probe(width: 1024, height: 1536, hasAudio: false, durationMs: 9000),
        VideoTarget.liveWallpaper,
      );
      expect(plan, live);
    });

    test('a canonical clip over the 15 MB ceiling is re-encoded', () {
      final plan = planVideo(
        _probe(
          width: 1024,
          height: 1824,
          hasAudio: false,
          durationMs: 9000,
          bytes: 16 * _mb,
        ),
        VideoTarget.liveWallpaper,
      );
      expect(plan, live);
    });
  });

  group('checkExport', () {
    const plan = ExportPlan(
      width: 1024,
      height: 1824,
      removeAudio: false,
      videoBitrate: 2000000,
      endMs: 29800,
      audioBitrate: 128000,
    );
    VideoProbe output({
      int width = 1024,
      int height = 1824,
      int bytes = 8 * _mb,
      bool hasAudio = true,
      int rotationDegrees = 0,
      int durationMs = 29810,
      String videoMime = 'video/avc',
    }) => _probe(
      width: width,
      height: height,
      bytes: bytes,
      hasAudio: hasAudio,
      rotationDegrees: rotationDegrees,
      durationMs: durationMs,
      videoMime: videoMime,
    );

    test('an output on the plan is ok', () {
      expect(checkExport(output(), plan, VideoTarget.status), ExportCheck.ok);
    });

    test('an output over the byte cap is tooLarge', () {
      expect(
        checkExport(output(bytes: 11 * _mb), plan, VideoTarget.status),
        ExportCheck.tooLarge,
      );
    });

    test(
      'an encoder fallback size, a rotation hint or a lost track is offPlan',
      () {
        for (final out in [
          output(width: 1088, height: 1920),
          output(rotationDegrees: 90),
          output(hasAudio: false),
          output(videoMime: 'video/hevc'),
          output(durationMs: 30100),
          output(bytes: 0),
        ]) {
          expect(
            checkExport(out, plan, VideoTarget.status),
            ExportCheck.offPlan,
          );
        }
      },
    );

    test('a live output must have shed its audio', () {
      const livePlan = ExportPlan(
        width: 1024,
        height: 1824,
        removeAudio: true,
        videoBitrate: 8000000,
      );
      expect(
        checkExport(
          output(hasAudio: false, durationMs: 9000),
          livePlan,
          VideoTarget.liveWallpaper,
        ),
        ExportCheck.ok,
      );
      expect(
        checkExport(
          output(durationMs: 9000),
          livePlan,
          VideoTarget.liveWallpaper,
        ),
        ExportCheck.offPlan,
      );
    });
  });

  test('withVideoBitrate changes only the bitrate', () {
    const plan = ExportPlan(
      width: 640,
      height: 1152,
      removeAudio: false,
      videoBitrate: 2000000,
      endMs: 29800,
      audioBitrate: 128000,
    );
    expect(
      plan.withVideoBitrate(1500000),
      const ExportPlan(
        width: 640,
        height: 1152,
        removeAudio: false,
        videoBitrate: 1500000,
        endMs: 29800,
        audioBitrate: 128000,
      ),
    );
  });

  group('VideoProbe.fromChannel', () {
    Map<String, Object?> raw({String? containerMime = 'video/mp4'}) => {
      'width': 1080,
      'height': 1920,
      'rotation': 90,
      'durationMs': 12345,
      'hasAudio': true,
      'videoMime': 'video/avc',
      'containerMime': containerMime,
      'bytes': 4567,
      'exportSupported': true,
    };

    test('reads every fact the native probe sends', () {
      final probe = VideoProbe.fromChannel(raw(), path: '/c/clip.MP4');
      expect(probe.width, 1080);
      expect(probe.height, 1920);
      expect(probe.rotationDegrees, 90);
      expect(probe.durationMs, 12345);
      expect(probe.hasAudio, isTrue);
      expect(probe.isH264, isTrue);
      expect(probe.bytes, 4567);
      expect(probe.isMp4, isTrue);
      expect(probe.exportSupported, isTrue);
    });

    test('only an .mp4 name in an MP4 container counts as MP4', () {
      expect(VideoProbe.fromChannel(raw(), path: '/c/clip.mov').isMp4, isFalse);
      expect(
        VideoProbe.fromChannel(
          raw(containerMime: 'video/webm'),
          path: '/c/clip.mp4',
        ).isMp4,
        isFalse,
      );
    });
  });
}
