import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

/// Any failure inside the watermark pipeline — asset load, decode, canvas, encode, transform.
/// Callers treat it as "share the original instead" — a watermark must never break the share.
class ShareWatermarkException implements Exception {
  const ShareWatermarkException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The device cannot burn a watermark into VIDEO at all, below API 31.
///
/// A DESIGNED outcome, not a failure -> a distinct type; the caller shares the clean original.
/// On a device that CAN watermark, a failure is a defect and fails the share instead.
/// Media3's `ExoPlayerAssetLoader.Factory` references an API-31 type with no `SDK_INT` guard.
/// So `Transformer.start()` throws `NoClassDefFoundError` on Android 11 and kills the process.
/// androidx/media#2535, open; 1.7.1 is the last clean release.
/// Statics are unaffected — that path never touches Media3.
class ShareWatermarkUnsupportedException extends ShareWatermarkException {
  ShareWatermarkUnsupportedException(this.sdkInt)
    : super('video watermarking needs API 31, device is API $sdkInt');

  /// The device's `Build.VERSION.SDK_INT` -> the skip rate splits by OS version, with no re-probe.
  final int sdkInt;
}

/// One share's watermark plan — WHERE the logo and code go, and WHICH code identifies this copy.
/// A leaked share is then traceable to the share EVENT, not just to the wallpaper.
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

class ShareWatermarkService {
  ShareWatermarkService({
    Future<Uint8List> Function()? loadLogoBytes,
    Random? random,
    MethodChannel? channel,
  }) : _loadLogoBytes = loadLogoBytes ?? _loadBundledLogo,
       _random = random ?? Random.secure(),
       _channel = channel ?? const MethodChannel(channelName);

  /// EXACT contract with the native side (built in parallel) — do not change.
  static const channelName = 'com.hsrutility.arul/share_watermark';

  static const _logoAsset = 'assets/images/watermark_logo.png';

  /// Layout constants, all FRAME-RELATIVE -> one pass serves a 1080x1920 static and a 1024x1824 clip.
  static const _logoWidthFrac = 0.14; // logo width : frame width
  static const _insetFrac = 0.04; // corner inset : frame width
  static const _codeFontFrac = 0.025; // code font size : frame height
  static const _opacity = 0.55;

  final Future<Uint8List> Function() _loadLogoBytes;
  final Random _random;
  final MethodChannel _channel;

  ui.Image? _logo; // decoded once, reused across shares

  /// Cached for the service's life — the OS version cannot change under a running process.
  ({bool supported, int sdkInt})? _videoSupport;

  static Future<Uint8List> _loadBundledLogo() async =>
      (await rootBundle.load(_logoAsset)).buffer.asUint8List();

  /// Picks a random corner for the logo, code diagonally opposite, and a fresh code for THIS share.
  WatermarkSpec plan({required String wallpaperId, String? userId}) {
    final corner = _random.nextInt(4);
    return WatermarkSpec(
      logoCorner: corner,
      code: _generateCode(wallpaperId: wallpaperId, userId: userId),
    );
  }

  /// 6–8 uppercase base36 chars, `AR-` prefixed.
  /// Mixes the user and wallpaper hashes and the clock into a random stream.
  /// So two shares of the same wallpaper by the same user in the same instant still differ.
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

  Future<ui.Image> _logoImage() async {
    final cached = _logo;
    if (cached != null) return cached;
    final bytes = await _loadLogoBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return _logo = frame.image;
  }

  /// Draws the brand mark and the unique code onto [canvas] for a [width]x[height] frame.
  ///
  /// The ONE overlay code path — the image pipeline composites it, the video pipeline exports it.
  /// Legibility comes from EDGE CONTRAST — a dark stroke and soft shadow under a white fill.
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

    // Brand mark: logo and wordmark as ONE group in the logo corner.
    // Laid out logo-first, wordmark-right -> it reads the same in every corner.
    // The GROUP's bounding box lands at the inset -> right corners right-align, nothing overflows.
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

    // Unique code, diagonally opposite, same legibility treatment.
    final (codeStroke, codeFill) = _labelPainters(
      spec.code,
      height * _codeFontFrac,
    );
    final codePos = corner(spec.codeCorner, codeFill.width, codeFill.height);
    codeStroke.paint(canvas, codePos);
    codeFill.paint(canvas, codePos);
  }

  /// A dark stroke pass under a white fill, with a soft drop shadow.
  ///
  /// `foreground` and `color` cannot both live on one [TextStyle] -> two painters.
  /// Shared by the wordmark and the code -> one tweak serves both, and both read on any background.
  /// The bundled 'Marcellus'; the engine falls back to the default typeface when it is unavailable.
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

  /// Draws [logo] into [dst] over a soft dark drop shadow — a blurred silhouette offset down-right.
  /// So the mark separates from bright backgrounds; the logo itself paints at [_opacity] on top.
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

  /// Longest edge a share decodes at.
  ///
  /// Canonical statics are 1080x1920, well under this -> real content is byte-for-byte unchanged.
  /// The cap only bites on an unexpectedly large master.
  /// That would materialise tens of MB of RGBA on the UI isolate, then COPY it into the encoder.
  static const _maxShareEdge = 2560;

  /// The dimensions to decode [w]x[h] at — capped to [_maxShareEdge] on the longer edge.
  /// Aspect-ratio-preserving and NEVER upscaled; a small source is returned as-is.
  (int, int) _cappedDecodeSize(int w, int h) {
    final long = w > h ? w : h;
    if (long <= _maxShareEdge) return (w, h);
    final scale = _maxShareEdge / long;
    return ((w * scale).round().clamp(1, w), (h * scale).round().clamp(1, h));
  }

  /// Decodes [src], composites the overlay, and writes a NEW quality-90 JPEG to [outPath].
  ///
  /// CAPPED on decode -> the decode, the raster pass and the RGBA readback are all bounded.
  /// Never mutates [src] — it may be a cache-manager entry.
  /// Encoding runs in [Isolate.run] -> the UI isolate never blocks on a full-resolution encode.
  /// The overlay layout is fully fractional -> the watermark lands identically at any frame size.
  /// Every intermediate is disposed EXPLICITLY — codec, descriptor, buffer and picture hold native
  /// memory the GC frees on its own schedule.
  /// On a low-RAM device that is far too late, with a decoded frame and two RGBA copies already held.
  Future<File> watermarkImage(
    File src,
    WatermarkSpec spec, {
    required String outPath,
  }) async {
    try {
      final srcBytes = await src.readAsBytes();

      // Read the header dimensions cheaply, then decode DOWN to the capped size — never up.
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
      // The decoded image is independent of these now -> release the encoded data.
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

  /// The overlay alone on a transparent [width]x[height] canvas, as PNG bytes.
  /// The input the native Media3 overlay effect composites over every frame.
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
  /// Asked BEFORE any work -> a device that cannot export never renders an overlay it discards.
  /// Anything unexpected — no channel, a malformed reply — reports UNSUPPORTED.
  /// Guessing wrong here used to be a dead app, so the pessimistic answer is the safe one.
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

  /// Burns the overlay into [src] via the native transformer.
  ///
  /// Live wallpapers are 1024x1824 BY RULE -> the overlay renders at exactly that size.
  /// The native side scales it to the frame anyway, and probing the container costs a full parse.
  /// Throws [ShareWatermarkUnsupportedException] below API 31 WITHOUT doing any work.
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
      // Codes: transform_failed | bad_input | unsupported_api.
      // The last appears only if the native gate disagrees with the probe -> honour it as a SKIP.
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

final shareWatermarkServiceProvider = Provider<ShareWatermarkService>(
  (ref) => ShareWatermarkService(),
);
