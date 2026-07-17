import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:arul/features/wallpapers/data/share_watermark_service.dart';

/// A tiny logo PNG generated in-memory (solid opaque gold square) so the tests
/// never depend on bundled-asset loading inside plain `flutter test` — the
/// service takes it through the `loadLogoBytes` constructor seam.
Uint8List _testLogoPng() {
  final logo = img.Image(width: 64, height: 64, numChannels: 4);
  img.fill(logo, color: img.ColorRgba8(212, 160, 23, 255));
  return img.encodePng(logo);
}

ShareWatermarkService _service({Random? random, MethodChannel? channel}) =>
    ShareWatermarkService(
      loadLogoBytes: () async => _testLogoPng(),
      random: random,
      channel: channel,
    );

/// Mean absolute per-channel RGB difference between the same [rect] region of
/// two images.
double _regionDiff(img.Image a, img.Image b, ({int x, int y, int w, int h}) r) {
  var sum = 0.0;
  var n = 0;
  for (var y = r.y; y < r.y + r.h; y++) {
    for (var x = r.x; x < r.x + r.w; x++) {
      final pa = a.getPixel(x, y);
      final pb = b.getPixel(x, y);
      sum +=
          (pa.r - pb.r).abs().toDouble() +
          (pa.g - pb.g).abs().toDouble() +
          (pa.b - pb.b).abs().toDouble();
      n += 3;
    }
  }
  return sum / n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('plan', () {
    test('code matches AR-[0-9A-Z]{6,8}', () {
      final service = _service();
      for (var i = 0; i < 50; i++) {
        final spec = service.plan(wallpaperId: 'w$i', userId: 'u1');
        expect(spec.code, matches(RegExp(r'^AR-[0-9A-Z]{6,8}$')));
      }
    });

    test('codes are unique across 100 plans (same wallpaper, same user)', () {
      final service = _service();
      final codes = {
        for (var i = 0; i < 100; i++)
          service.plan(wallpaperId: 'w1', userId: 'u1').code,
      };
      expect(codes, hasLength(100));
    });

    test('code corner is always diagonally opposite the logo corner', () {
      final service = _service();
      for (var i = 0; i < 200; i++) {
        final spec = service.plan(wallpaperId: 'w1');
        expect(spec.logoCorner, inInclusiveRange(0, 3));
        expect(spec.codeCorner, (spec.logoCorner + 2) % 4);
      }
    });

    test('all four logo corners occur', () {
      final service = _service();
      final corners = {
        for (var i = 0; i < 200; i++)
          service.plan(wallpaperId: 'w1').logoCorner,
      };
      expect(corners, {0, 1, 2, 3});
    });
  });

  group('watermarkImage', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('arul_wm_test');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes a same-size JPEG whose chosen corners changed and whose '
        'center did not', () async {
      const w = 400, h = 700;

      // Solid mid-gray source JPEG on disk.
      final source = img.Image(width: w, height: h);
      img.fill(source, color: img.ColorRgb8(90, 90, 90));
      final srcFile = File('${tmp.path}/src.jpg')
        ..writeAsBytesSync(img.encodeJpg(source, quality: 95));

      // Fixed spec: logo top-left (0) → code bottom-right (2).
      const spec = WatermarkSpec(logoCorner: 0, code: 'AR-TESTXY');
      final outPath = '${tmp.path}/out-wm-TESTXY.jpg';

      final out = await _service().watermarkImage(
        srcFile,
        spec,
        outPath: outPath,
      );

      expect(out.path, outPath);
      expect(out.existsSync(), isTrue);
      final decodedSrc = img.decodeJpg(srcFile.readAsBytesSync())!;
      final decoded = img.decodeJpg(out.readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, w);
      expect(decoded.height, h);

      // Logo region: ~14% of width at ~4% inset, top-left.
      final inset = (w * 0.04).round();
      final logoSize = (w * 0.14).round();
      final logoRegion = (x: inset, y: inset, w: logoSize, h: logoSize);
      // Code region: bottom-right corner block (text height ~2.5% of h).
      final codeRegion = (
        x: w - inset - logoSize,
        y: h - inset - (h * 0.03).round(),
        w: logoSize,
        h: (h * 0.03).round(),
      );
      // Untouched center block.
      final center = (x: w ~/ 2 - 40, y: h ~/ 2 - 40, w: 80, h: 80);

      expect(
        _regionDiff(decoded, decodedSrc, logoRegion),
        greaterThan(10),
        reason: 'logo corner should visibly differ from the source',
      );
      expect(
        _regionDiff(decoded, decodedSrc, codeRegion),
        greaterThan(2),
        reason: 'code corner should visibly differ from the source',
      );
      expect(
        _regionDiff(decoded, decodedSrc, center),
        lessThan(3),
        reason: 'center must be untouched (JPEG round-trip noise only)',
      );
    });

    test('wraps decode failure in ShareWatermarkException', () async {
      final srcFile = File('${tmp.path}/garbage.jpg')
        ..writeAsBytesSync([1, 2, 3, 4]);
      expect(
        () => _service().watermarkImage(
          srcFile,
          const WatermarkSpec(logoCorner: 0, code: 'AR-TESTXY'),
          outPath: '${tmp.path}/out.jpg',
        ),
        throwsA(isA<ShareWatermarkException>()),
      );
    });
  });

  group('renderOverlayPng', () {
    test('returns a decodable full-frame transparent PNG', () async {
      final bytes = await _service().renderOverlayPng(
        const WatermarkSpec(logoCorner: 1, code: 'AR-TESTXY'),
        width: 256,
        height: 456,
      );
      final png = img.decodePng(bytes);
      expect(png, isNotNull);
      expect(png!.width, 256);
      expect(png.height, 456);
      // Center is fully transparent; the logo corner (top-right) is not.
      expect(png.getPixel(128, 228).a, 0);
      final inset = (256 * 0.04).round();
      final logoW = (256 * 0.14).round();
      var maxAlpha = 0;
      for (var y = inset; y < inset + logoW; y++) {
        for (var x = 256 - inset - logoW; x < 256 - inset; x++) {
          maxAlpha = max(maxAlpha, png.getPixel(x, y).a.toInt());
        }
      }
      expect(maxAlpha, greaterThan(0));
    });
  });

  group('watermarkVideo', () {
    const channel = MethodChannel(ShareWatermarkService.channelName);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'invokes the exact platform contract and returns the output file',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return (call.arguments as Map)['outputPath'] as String;
            });

        const spec = WatermarkSpec(logoCorner: 2, code: 'AR-TESTXY');
        final out = await _service().watermarkVideo(
          File('/in/clip.mp4'),
          spec,
          outPath: '/out/clip-wm-AR-TESTXY.mp4',
        );

        expect(out.path, '/out/clip-wm-AR-TESTXY.mp4');
        expect(calls, hasLength(1));
        final call = calls.single;
        expect(call.method, 'watermarkVideo');
        final args = (call.arguments as Map).cast<String, Object?>();
        expect(
          args.keys,
          unorderedEquals(['inputPath', 'outputPath', 'overlayPng']),
        );
        expect(args['inputPath'], '/in/clip.mp4');
        expect(args['outputPath'], '/out/clip-wm-AR-TESTXY.mp4');
        final overlay = args['overlayPng'];
        expect(overlay, isA<Uint8List>());
        // The overlay is a real 1024x1824 PNG (the live-video frame size).
        final png = img.decodePng(overlay! as Uint8List);
        expect(png!.width, 1024);
        expect(png.height, 1824);
      },
    );

    test('maps PlatformException codes to ShareWatermarkException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'transform_failed', message: 'boom');
          });

      expect(
        () => _service().watermarkVideo(
          File('/in/clip.mp4'),
          const WatermarkSpec(logoCorner: 3, code: 'AR-TESTXY'),
          outPath: '/out/x.mp4',
        ),
        throwsA(
          isA<ShareWatermarkException>().having(
            (e) => e.message,
            'message',
            contains('transform_failed'),
          ),
        ),
      );
    });
  });
}
