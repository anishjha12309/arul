import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

// ─── Exception ───────────────────────────────────────────────────────────────

/// Any failure inside the watermark pipeline (asset load, decode, canvas,
/// encode, native transform). Callers treat it as "share the original instead"
/// — a watermark must never break the share itself.
class ShareWatermarkException implements Exception {
  const ShareWatermarkException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The device cannot burn a watermark into VIDEO at all (below API 31).
///
/// Deliberately a distinct type, because it is a DESIGNED outcome rather than a
/// failure: the caller shares the clean original and shows the user nothing. On
/// a device that CAN watermark, a failure is treated as a defect and fails the
/// share instead — see `wallpaper_share_provider`.
///
/// Why API 31: Media3's `ExoPlayerAssetLoader.Factory` references
/// `android.media.metrics.LogSessionId` (an API-31 type) from a field, a
/// constructor parameter and `createAssetLoader`, with no `SDK_INT` guard, so
/// `Transformer.start()` throws `NoClassDefFoundError` on Android 11 and below
/// and kills the process. androidx/media#2535, open; 1.7.1 is the last clean
/// release. Statics are unaffected — that path never touches Media3.
class ShareWatermarkUnsupportedException extends ShareWatermarkException {
  ShareWatermarkUnsupportedException(this.sdkInt)
    : super('video watermarking needs API 31, device is API $sdkInt');

  /// The device's `Build.VERSION.SDK_INT`, reported so the skip rate can be
  /// broken down by OS version without a second probe.
  final int sdkInt;
}

// ─── Spec ────────────────────────────────────────────────────────────────────

/// One share's watermark plan: WHERE the logo and code go, and WHICH unique
/// code identifies this particular copy (a leaked share is traceable to the
/// share event, not just the wallpaper).
///
/// Corners: 0 = top-left, 1 = top-right, 2 = bottom-right, 3 = bottom-left.
/// The code always sits diagonally opposite the logo.
class WatermarkSpec {
  const WatermarkSpec({required this.logoCorner, required this.code})
    : assert(logoCorner >= 0 && logoCorner <= 3);

  final int logoCorner;

  /// `AR-` + 6–8 uppercase base36 chars, unique per share.
  final String code;

  int get codeCorner => (logoCorner + 2) % 4;
}

// ─── Service ─────────────────────────────────────────────────────────────────

class ShareWatermarkService {
  ShareWatermarkService({
    Future<Uint8List> Function()? loadLogoBytes,
    Random? random,
    MethodChannel? channel,
  }) : _loadLogoBytes = loadLogoBytes ?? _loadBundledLogo,
       _random = random ?? Random.secure(),
       _channel = channel ?? const MethodChannel(channelName);

  /// EXACT contract with the native side (built in parallel) — do not change.
  static const channelName = 'com.hsrapps.arul/share_watermark';

  static const _logoAsset = 'assets/images/watermark_logo.png';

  /// Layout constants, all relative to the frame so one overlay pass serves
  /// both a ~1080x1920 static and a 1024x1824 live frame identically.
  static const _logoWidthFrac = 0.14; // logo width : frame width
  static const _insetFrac = 0.04; // corner inset : frame width
  static const _codeFontFrac = 0.025; // code font size : frame height
  static const _opacity = 0.55;

  final Future<Uint8List> Function() _loadLogoBytes;
  final Random _random;
  final MethodChannel _channel;

  ui.Image? _logo; // decoded once, reused across shares

  /// Cached for the life of the service — the OS version cannot change under a
  /// running process, and every live share would otherwise re-ask.
  ({bool supported, int sdkInt})? _videoSupport;

  static Future<Uint8List> _loadBundledLogo() async =>
      (await rootBundle.load(_logoAsset)).buffer.asUint8List();

  // ─── Planning ──────────────────────────────────────────────────────────────

  /// Picks a random corner for the logo (code goes diagonally opposite) and
  /// generates a fresh unique code for THIS share.
  WatermarkSpec plan({required String wallpaperId, String? userId}) {
    final corner = _random.nextInt(4);
    return WatermarkSpec(
      logoCorner: corner,
      code: _generateCode(wallpaperId: wallpaperId, userId: userId),
    );
  }

  /// 6–8 uppercase base36 chars, `AR-` prefixed. Mixes the user + wallpaper
  /// hashes and the clock into a random stream, so two shares of the same
  /// wallpaper by the same user in the same instant still differ.
  String _generateCode({required String wallpaperId, String? userId}) {
    const alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    var mix = Object.hash(
      userId,
      wallpaperId,
      DateTime.now().microsecondsSinceEpoch,
    );
    final length = 6 + _random.nextInt(3); // 6..8
    final out = StringBuffer('AR-');
    for (var i = 0; i < length; i++) {
      mix = 0x3fffffff & (mix * 31 + _random.nextInt(1 << 24));
      out.write(alphabet[mix % alphabet.length]);
    }
    return out.toString();
  }

  // ─── Overlay (shared by image + video paths) ───────────────────────────────

  Future<ui.Image> _logoImage() async {
    final cached = _logo;
    if (cached != null) return cached;
    final bytes = await _loadLogoBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return _logo = frame.image;
  }

  /// Draws the brand mark (logo + "Arul" wordmark) and the unique code onto
  /// [canvas] for a [width]x[height] frame. The ONE overlay code path: the
  /// image pipeline composites it over the decoded source; the video pipeline
  /// exports it alone as a transparent PNG. Legibility comes from edge contrast
  /// (dark stroke + soft shadow under a white fill), not from raw opacity.
  Future<void> _drawOverlay(
    ui.Canvas canvas,
    WatermarkSpec spec,
    double width,
    double height,
  ) async {
    final logo = await _logoImage();

    final inset = width * _insetFrac;
    final logoW = width * _logoWidthFrac;
    final logoH = logoW * logo.height / logo.width;

    // Top-left of an [itemW]x[itemH] box tucked into corner [c] at the inset.
    Offset corner(int c, double itemW, double itemH) => Offset(
      c == 0 || c == 3 ? inset : width - inset - itemW,
      c == 0 || c == 1 ? inset : height - inset - itemH,
    );

    // ── Brand mark: logo + wordmark treated as one group in the logo corner ──
    // Cap-height of "Arul" roughly matches the logo height; laid out logo-first,
    // wordmark-right, so it reads the same in every corner. The group's bounding
    // box is what lands at the inset, so right corners right-align cleanly (the
    // whole width + gap is accounted for) and nothing overflows the frame.
    final brandFontSize = logoH * 0.6;
    final (wordStroke, wordFill) = _labelPainters('Arul', brandFontSize);
    final gap = logoW * 0.15;
    final groupW = logoW + gap + wordFill.width;
    final groupH = max(logoH, wordFill.height);
    final group = corner(spec.logoCorner, groupW, groupH);

    _drawLogo(
      canvas,
      logo,
      Rect.fromLTWH(
        group.dx,
        group.dy + (groupH - logoH) / 2, // vertically centered in the group
        logoW,
        logoH,
      ),
      logoW,
    );
    final wordOffset = Offset(
      group.dx + logoW + gap,
      group.dy + (groupH - wordFill.height) / 2, // centered against the logo
    );
    wordStroke.paint(canvas, wordOffset);
    wordFill.paint(canvas, wordOffset);

    // ── Unique code, diagonally opposite, same legibility treatment ──
    final (codeStroke, codeFill) = _labelPainters(
      spec.code,
      height * _codeFontFrac,
    );
    final codePos = corner(spec.codeCorner, codeFill.width, codeFill.height);
    codeStroke.paint(canvas, codePos);
    codeFill.paint(canvas, codePos);
  }

  /// A dark stroke pass under a white fill with a soft drop shadow. Two
  /// painters because `foreground` (the stroke) and `color` (the fill) can't
  /// both live on one [TextStyle]. Shared by the wordmark and the code so a
  /// single tweak serves both, and both read on any background.
  ///
  /// The bundled display serif ('Marcellus'); the engine falls back to the
  /// default typeface when the family is unavailable (plain `flutter test`).
  (TextPainter, TextPainter) _labelPainters(String value, double fontSize) {
    TextPainter build(TextStyle style) => TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();

    final stroke = build(
      TextStyle(
        fontFamily: 'Marcellus',
        fontSize: fontSize,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = fontSize * 0.09
          ..color = const Color.fromRGBO(0, 0, 0, 0.5),
      ),
    );
    final fill = build(
      TextStyle(
        fontFamily: 'Marcellus',
        fontSize: fontSize,
        color: const Color.fromRGBO(255, 255, 255, _opacity),
        shadows: [
          Shadow(
            color: const Color.fromRGBO(0, 0, 0, 0.55),
            blurRadius: fontSize * 0.28,
            offset: Offset(0, fontSize * 0.05),
          ),
        ],
      ),
    );
    return (stroke, fill);
  }

  /// Draws [logo] into [dst] with a soft dark drop shadow beneath — a blurred
  /// black silhouette (srcIn tint) offset down-right — so the mark separates
  /// from bright backgrounds, then the logo itself at [_opacity] on top.
  void _drawLogo(ui.Canvas canvas, ui.Image logo, Rect dst, double logoW) {
    final src = Rect.fromLTWH(
      0,
      0,
      logo.width.toDouble(),
      logo.height.toDouble(),
    );
    canvas.drawImageRect(
      logo,
      src,
      dst.shift(Offset(logoW * 0.015, logoW * 0.02)),
      Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = const ui.ColorFilter.mode(
          Color.fromRGBO(0, 0, 0, 0.5),
          ui.BlendMode.srcIn,
        )
        ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, logoW * 0.02),
    );
    canvas.drawImageRect(
      logo,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..color = const Color.fromRGBO(255, 255, 255, _opacity),
    );
  }

  // ─── Image path ────────────────────────────────────────────────────────────

  /// Longest edge a share decodes at. Canonical statics are 1080x1920
  /// (docs/media-conventions.md), already well under this, so real content
  /// decodes at its native size and its output is byte-for-byte unchanged. The
  /// cap only bites on an unexpectedly large master — which would otherwise
  /// materialise tens of MB of uncompressed RGBA on the UI isolate and then
  /// COPY all of it into the encode isolate.
  static const _maxShareEdge = 2560;

  /// The frame dimensions to decode [w]x[h] at: capped to [_maxShareEdge] on the
  /// longer edge, aspect-ratio-preserving, and NEVER upscaled (a small source is
  /// returned as-is). See [watermarkImage].
  (int, int) _cappedDecodeSize(int w, int h) {
    final long = w > h ? w : h;
    if (long <= _maxShareEdge) return (w, h);
    final scale = _maxShareEdge / long;
    return ((w * scale).round().clamp(1, w), (h * scale).round().clamp(1, h));
  }

  /// Decodes [src] (jpg/webp) — CAPPED to a phone-appropriate resolution so the
  /// decode, the raster pass and the uncompressed RGBA readback are all bounded
  /// — composites the overlay, and writes a NEW quality-90 JPEG to [outPath]
  /// (never mutates [src] — it may be a cache-manager entry). JPEG encoding runs
  /// in [Isolate.run] so the UI isolate never blocks on a full-resolution
  /// encode. The overlay layout is fully fractional, so the watermark lands
  /// identically at any frame size.
  ///
  /// Every intermediate is disposed explicitly. The codec, the descriptor, its
  /// buffer and the recorded picture each hold native memory that the GC frees
  /// only on its own schedule — which on a low-RAM device is far too late when
  /// a share is already holding a decoded frame, a composited frame and two
  /// copies of the RGBA buffer.
  Future<File> watermarkImage(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    try {
      final srcBytes = await src.readAsBytes();

      // Read the header dimensions cheaply (no full decode), then decode DOWN
      // to the capped size. Only ever downscales.
      final buffer = await ui.ImmutableBuffer.fromUint8List(srcBytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final (targetW, targetH) = _cappedDecodeSize(
        descriptor.width,
        descriptor.height,
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: targetW,
        targetHeight: targetH,
      );
      final frame = await codec.getNextFrame();
      final source = frame.image;
      // The decoded image is independent of these now — release the encoded data.
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();

      final w = source.width;
      final h = source.height;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(source, Offset.zero, Paint());
      await _drawOverlay(canvas, spec, w.toDouble(), h.toDouble());

      final picture = recorder.endRecording();
      final composed = await picture.toImage(w, h);
      picture.dispose();
      final rgba = await composed.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      composed.dispose();
      source.dispose();
      if (rgba == null) {
        throw const ShareWatermarkException('composited toByteData failed');
      }

      final pixels = rgba.buffer.asUint8List(
        rgba.offsetInBytes,
        rgba.lengthInBytes,
      );
      final jpeg = await Isolate.run(() {
        final image = img.Image.fromBytes(
          width: w,
          height: h,
          bytes: pixels.buffer,
          bytesOffset: pixels.offsetInBytes,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
        return img.encodeJpg(image, quality: 90);
      });

      final out = File(outPath);
      await out.writeAsBytes(jpeg, flush: true);
      return out;
    } on ShareWatermarkException {
      rethrow;
    } catch (e) {
      throw ShareWatermarkException('image watermark failed: $e');
    }
  }

  // ─── Video path ────────────────────────────────────────────────────────────

  /// The overlay alone on a transparent [width]x[height] canvas as PNG bytes —
  /// the input the native Media3 overlay effect composites over every frame.
  Future<Uint8List> renderOverlayPng(
    WatermarkSpec spec, {
    required int width,
    required int height,
  }) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      await _drawOverlay(canvas, spec, width.toDouble(), height.toDouble());
      final image = await recorder.endRecording().toImage(width, height);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) {
        throw const ShareWatermarkException('overlay toByteData failed');
      }
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } on ShareWatermarkException {
      rethrow;
    } catch (e) {
      throw ShareWatermarkException('overlay render failed: $e');
    }
  }

  /// Whether this device can burn a watermark into video, and its API level.
  ///
  /// Asked before any work is done, so a device that cannot export never pays
  /// for an overlay render it would only throw away. Anything unexpected — no
  /// channel (plain `flutter test`), a malformed reply — reports UNSUPPORTED:
  /// the failure mode of guessing wrong here used to be a dead app, so the
  /// pessimistic answer is the safe one.
  Future<({bool supported, int sdkInt})> videoWatermarkSupport() async {
    final cached = _videoSupport;
    if (cached != null) return cached;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'videoWatermarkSupport',
      );
      return _videoSupport = (
        supported: raw?['supported'] as bool? ?? false,
        sdkInt: raw?['sdkInt'] as int? ?? 0,
      );
    } on Object {
      return _videoSupport = (supported: false, sdkInt: 0);
    }
  }

  /// Burns the overlay into [src] (an MP4) via the native transformer.
  /// Live wallpapers are 1024x1824 BY RULE (docs/media-conventions.md), so the
  /// overlay is rendered at exactly that size — the native side scales it to
  /// the frame anyway, and probing the container here would cost a full parse.
  ///
  /// Throws [ShareWatermarkUnsupportedException] below API 31 WITHOUT doing any
  /// work; the caller shares the clean original in that case.
  Future<File> watermarkVideo(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    final support = await videoWatermarkSupport();
    if (!support.supported) {
      throw ShareWatermarkUnsupportedException(support.sdkInt);
    }
    final overlay = await renderOverlayPng(spec, width: 1024, height: 1824);
    try {
      final result = await _channel.invokeMethod<String>('watermarkVideo', {
        'inputPath': src.path,
        'outputPath': outPath,
        'overlayPng': overlay,
      });
      return File(result ?? outPath);
    } on PlatformException catch (e) {
      // codes: transform_failed | bad_input | unsupported_api. The last one can
      // only appear if the native gate disagrees with the probe above; honour it
      // as a skip rather than a failure so the share still goes out.
      if (e.code == 'unsupported_api') {
        throw ShareWatermarkUnsupportedException(support.sdkInt);
      }
      throw ShareWatermarkException(
        'video watermark failed (${e.code}): ${e.message}',
      );
    } on MissingPluginException {
      throw const ShareWatermarkException('watermark channel unavailable');
    }
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────

final shareWatermarkServiceProvider = Provider<ShareWatermarkService>(
  (ref) => ShareWatermarkService(),
);
