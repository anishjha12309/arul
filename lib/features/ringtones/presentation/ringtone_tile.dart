/// The ringtone list's row artwork: a bundled gold deity figure on a jewel-tone
/// ground, with an oil-lamp diya raised over it while the track previews.
///
/// Three layers, bottom to top:
///   1. a gradient ground with a hairline rim, and a ring of kolam pulli dots
///      framing the tile — both drawn, both hashed per track ([RingtoneTileSpec])
///   2. the deity PNG ([deityAsset]) — the only fetched-from-disk part
///   3. only while previewing, a scrim + diya whose flame sways
///
/// ── WHAT THIS FILE USED TO BE ──────────────────────────────────────────────
/// Layer 2 was six hand-drawn `CustomPainter` motifs (vel, trishul, lotus,
/// shankha, 18 steps, gopuram) chosen by `category`. They are gone. A motif per
/// category can only ever be as specific as the browse axis, and the browse
/// axis is deliberately coarse — so all 35 `perumal` tracks wore one shankha
/// whether they were to Venkateswara, Krishna, Rama or Narasimha. The art is
/// now keyed by `deity`, which the drawn approach had no way to express.
///
/// The ground and the kolam ring survived on purpose: they are what stops 35
/// Murugan tracks — one deity, one PNG — from being 35 identical tiles. Ten
/// grounds and three dot counts, hashed off the track id, still make each row
/// look like itself. The ring moved out from radius 15 to 21 so it frames the
/// figure instead of being drawn underneath it, and the dashed circle that used
/// to be woven through it is gone: at the new radius it sat a hair inside the
/// rim and read as a mis-drawn border rather than a kolam.
///
/// ── COLOUR NOTE ────────────────────────────────────────────────────────────
/// The ten gradient grounds, the `#EBD6A3` gold ink, the scrim and the diya's
/// flame colours below are ARTWORK, not UI chrome. They are the palette of one
/// drawing — they have no role anywhere else in the app and must never grow
/// into `ArulTokens`. Every value that *is* chrome (radius, sizes, motion) does
/// come from the tokens. The PNGs are inked in that same `#EBD6A3`, so the
/// constant below and the asset pipeline have to move together.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/arul_tokens.dart';
import 'deity_art.dart';

/// Everything that makes one tile's GROUND look like itself.
///
/// Built by [RingtoneTileSpec.forRingtone], a PURE function of the track's id —
/// the catalog carries no art parameters. Never seed this from a list index:
/// the same track would change costume whenever a category filter re-ordered
/// the list.
///
/// The deity figure is deliberately NOT part of this spec. It is a fact about
/// the track, not a hashed decoration, and it comes from the catalog.
@immutable
class RingtoneTileSpec {
  const RingtoneTileSpec({
    required this.groundIndex,
    required this.dotCount,
    required this.rotationDegrees,
  });

  /// Index into the ten jewel-tone grounds.
  final int groundIndex;

  /// Pulli dots on the kolam ring — 8, 12 or 16.
  final int dotCount;

  /// Where the first pulli dot sits, in degrees.
  final double rotationDegrees;

  /// How many grounds exist; also the modulus [groundIndex] is reduced by.
  static const int groundCount = 10;

  /// The dot counts the handoff allows.
  static const List<int> dotCounts = [8, 12, 16];

  /// The deterministic derivation. Same id → same spec, always.
  ///
  /// Each parameter is hashed from its OWN salted string rather than from
  /// different bit-slices of one hash. Catalog ids are short and share long
  /// prefixes ("rt-amman-01", "rt-amman-02"); slicing one FNV hash left whole
  /// fields nearly constant across such a set, and a screen of tiles that all
  /// chose the same dot count is exactly the sameness this ground exists to
  /// avoid. Three hashes of a short string per tile is nothing.
  factory RingtoneTileSpec.forRingtone({required String id}) {
    return RingtoneTileSpec(
      groundIndex: _hash('$id:ground') % groundCount,
      dotCount: dotCounts[_hash('$id:dots') % dotCounts.length],
      rotationDegrees: (_hash('$id:rotation') % 360).toDouble(),
    );
  }

  /// FNV-1a with a Murmur3 `fmix32` avalanche on the way out, 32-bit.
  ///
  /// Chosen over [String.hashCode] deliberately: Dart's string hash is not
  /// guaranteed stable across runs or SDK versions, and a tile that silently
  /// re-rolled its ground on an app update would be a bug nobody could
  /// reproduce.
  ///
  /// The avalanche is not decoration. Plain FNV-1a mixes the LAST bytes least,
  /// so every `'$id:ground'` — which all end in the same salt — landed in a
  /// handful of buckets, and four of eight sample tiles drew the same ground.
  /// fmix32 spreads each input bit across the whole word before the modulus
  /// sees it.
  static int _hash(String s) {
    var h = 0x811C9DC5;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    h ^= h >>> 16;
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF;
    h ^= h >>> 13;
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF;
    return h ^ (h >>> 16);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RingtoneTileSpec &&
          other.groundIndex == groundIndex &&
          other.dotCount == dotCount &&
          other.rotationDegrees == rotationDegrees;

  @override
  int get hashCode => Object.hash(groundIndex, dotCount, rotationDegrees);

  @override
  String toString() =>
      'RingtoneTileSpec(ground: $groundIndex, dots: $dotCount, '
      'rot: $rotationDegrees)';
}

/// One row's artwork. Pass [playing] to raise the scrim + diya over it.
///
/// The flame's 1100ms sway ([ArulTokens.diyaFlicker]) is driven straight into
/// the painter through `CustomPaint.foregroundPainter.repaint`, so a playing
/// tile repaints without ever rebuilding a widget — and the ticker only runs
/// while this row is the playing one. `MediaQuery.disableAnimations` holds the
/// flame still with the glow parked at 0.4.
class RingtoneTile extends StatefulWidget {
  const RingtoneTile({
    super.key,
    required this.spec,
    required this.assetPath,
    required this.playing,
    this.size = defaultSize,
  });

  final RingtoneTileSpec spec;

  /// Resolved by [deityAsset] — always a path with a real file behind it.
  final String assetPath;

  final bool playing;
  final double size;

  /// The row's art size. Grew from 46 with the second text line: a one-line row
  /// balanced at 46, a title-over-subtitle stack does not.
  static const double defaultSize = 52;

  @override
  State<RingtoneTile> createState() => _RingtoneTileState();
}

class _RingtoneTileState extends State<RingtoneTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ArulTokens.diyaFlicker,
  );

  /// `ease-in-out … alternate`: the easing applies to each direction, so the
  /// reverse curve is the same curve rather than its inverse.
  late final Animation<double> _flicker = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
    reverseCurve: Curves.easeInOut,
  );

  bool _reduceMotion = false;
  double _devicePixelRatio = 3;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _reduceMotion = media.disableAnimations;
    _devicePixelRatio = media.devicePixelRatio;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant RingtoneTile old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) _syncTicker();
  }

  void _syncTicker() {
    final animate = widget.playing && !_reduceMotion;
    if (animate) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else if (_controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The PNGs are authored at 512² but never drawn larger than ~180 physical
    // pixels. Decoding them at source size would hold ~1 MB of bitmap EACH —
    // 17 MB across the set — for a 52dp tile. cacheWidth decodes at the size
    // actually painted; the image cache keys on it, so the 35 Murugan rows
    // still share one decode.
    final cachePx = (widget.size * _devicePixelRatio).round();

    return RepaintBoundary(
      child: CustomPaint(
        // Ground + kolam behind the figure, diya in front of it — the scrim has
        // to cover the art, so it cannot share a painter with the ground.
        painter: RingtoneTileGroundPainter(spec: widget.spec),
        foregroundPainter: RingtoneTileDiyaPainter(
          playing: widget.playing,
          reduceMotion: _reduceMotion,
          flicker: _flicker,
        ),
        size: Size.square(widget.size),
        child: SizedBox.square(
          dimension: widget.size,
          child: Image.asset(
            widget.assetPath,
            cacheWidth: cachePx,
            cacheHeight: cachePx,
            filterQuality: FilterQuality.medium,
            // A bundled asset cannot 404, but a mis-typed path in the resolver
            // would throw mid-paint and take the whole list down. An empty box
            // leaves the ground and the title readable instead.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// Ground + kolam ring. Everything under the deity figure.
class RingtoneTileGroundPainter extends CustomPainter {
  const RingtoneTileGroundPainter({required this.spec});

  final RingtoneTileSpec spec;

  /// The ten jewel-tone temple grounds, `(top-left, bottom-right)`.
  static const List<(Color, Color)> _grounds = [
    (Color(0xFF5C1226), Color(0xFF2A0A12)), // maroon
    (Color(0xFF0E3B2E), Color(0xFF07231B)), // temple green
    (Color(0xFF1E2159), Color(0xFF0E0F2E)), // indigo
    (Color(0xFF0B4550), Color(0xFF04252C)), // peacock teal
    (Color(0xFF7A5410), Color(0xFF3A2606)), // turmeric ochre
    (Color(0xFF40154A), Color(0xFF210A28)), // aubergine
    (Color(0xFF6B2A12), Color(0xFF33130A)), // brick
    (Color(0xFF5E1839), Color(0xFF2C0A1B)), // deep rose
    (Color(0xFF3F4A12), Color(0xFF1E2408)), // olive
    (Color(0xFF12335A), Color(0xFF08192E)), // navy
  ];

  /// One warm gold ink — the same value the deity PNGs are drawn in.
  static const Color _ink = Color(0xFFEBD6A3);

  /// The authoring viewBox: every coordinate below is in 46-unit space and is
  /// scaled to the real tile size, which is [RingtoneTile.defaultSize].
  static const double _vb = 46;
  static const Offset _centre = Offset(23, 23);

  /// Where the pulli dots sit. 21 of 23 puts them just inside the rim, framing
  /// the figure; at the old 15 they were underneath it.
  static const double _ringRadius = 21;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _vb);

    const rect = Rect.fromLTWH(0, 0, _vb, _vb);
    final rrect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(ArulTokens.coverRadius),
    );
    final (from, to) = _grounds[spec.groundIndex % _grounds.length];
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft, // 135°
          end: Alignment.bottomRight,
          colors: [from, to],
        ).createShader(rect),
    );

    // Inset hairline rim: 0.5 in, radius 12.5, so the stroke sits just inside
    // the tile's own corner instead of straddling it.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0.5, 0.5, _vb - 1, _vb - 1),
        const Radius.circular(ArulTokens.coverRadius - 0.5),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = _ink.withValues(alpha: 0.18),
    );

    final dot = Paint()..color = _ink.withValues(alpha: 0.5);
    final step = 2 * math.pi / spec.dotCount;
    final start = spec.rotationDegrees * math.pi / 180;
    for (var i = 0; i < spec.dotCount; i++) {
      final a = start + i * step;
      canvas.drawCircle(
        _centre + Offset(math.cos(a), math.sin(a)) * _ringRadius,
        1.05,
        dot,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(RingtoneTileGroundPainter old) => old.spec != spec;
}

/// The now-playing diya, painted OVER the deity figure.
class RingtoneTileDiyaPainter extends CustomPainter {
  RingtoneTileDiyaPainter({
    required this.playing,
    required this.reduceMotion,
    required this.flicker,
  }) : super(repaint: playing && !reduceMotion ? flicker : null);

  final bool playing;
  final bool reduceMotion;

  /// 0 → 1 → 0 over two [ArulTokens.diyaFlicker] beats. Read only while
  /// [playing] and motion is allowed.
  final Animation<double> flicker;

  static const Color _ink = Color(0xFFEBD6A3);

  /// The now-playing scrim.
  static const Color _scrim = Color.fromRGBO(14, 6, 8, 0.66);

  /// The diya: glow core, glow falloff, bowl fill, flame.
  static const Color _glowCore = Color(0xFFF4DFA8);
  static const Color _glowEdge = Color(0xFFD4A017);
  static const Color _bowlFill = Color.fromRGBO(212, 160, 23, 0.35);
  static const Color _flameFill = Color(0xFFF6E3AE);

  static const double _vb = 46;

  /// The handoff's three flame keyframes: `rotate(-4°) scaleY(.94)` →
  /// `rotate(2°) scaleY(1.05)` → `rotate(-2°) scaleY(.97)`, about (23, 30).
  static const List<(double, double)> _flameFrames = [
    (-4, 0.94),
    (2, 1.05),
    (-2, 0.97),
  ];

  /// The glow's opacity on the same three keyframes.
  static const List<double> _glowFrames = [0.28, 0.5, 0.32];

  /// The glow opacity when motion is suppressed — a single held value rather
  /// than the middle of the pulse.
  static const double _glowStill = 0.4;

  @override
  void paint(Canvas canvas, Size size) {
    if (!playing) return;

    canvas.save();
    canvas.scale(size.width / _vb);

    const rect = Rect.fromLTWH(0, 0, _vb, _vb);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(ArulTokens.coverRadius),
      ),
      Paint()..color = _scrim,
    );

    final t = reduceMotion ? null : flicker.value;

    // Glow.
    const glowCentre = Offset(23, 21);
    const glowRadius = 9.0;
    final glowOpacity = t == null ? _glowStill : _sample(_glowFrames, t);
    final glowBox = Rect.fromCircle(center: glowCentre, radius: glowRadius);
    canvas.drawCircle(
      glowCentre,
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _glowCore.withValues(alpha: 0.75 * glowOpacity),
            _glowEdge.withValues(alpha: 0),
          ],
        ).createShader(glowBox),
    );

    // Bowl + base.
    final bowl = Path()
      ..moveTo(14.6, 27.6)
      ..cubicTo(16.6, 32.4, 29.4, 32.4, 31.4, 27.6)
      ..close();
    canvas
      ..drawPath(bowl, Paint()..color = _bowlFill)
      ..drawPath(
        bowl,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..strokeJoin = StrokeJoin.round
          ..color = _ink,
      )
      ..drawLine(
        const Offset(17.4, 32.4),
        const Offset(28.6, 32.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..strokeCap = StrokeCap.round
          ..color = _ink,
      );

    // Flame, swaying about its base.
    final flame = Path()
      ..moveTo(23, 26.4)
      ..cubicTo(25.8, 23.6, 24.8, 19.6, 23, 16.6)
      ..cubicTo(21.2, 19.6, 20.2, 23.6, 23, 26.4)
      ..close();

    canvas.save();
    if (t != null) {
      final (degrees, scaleY) = _sampleFrame(t);
      const origin = Offset(23, 30);
      canvas
        ..translate(origin.dx, origin.dy)
        ..rotate(degrees * math.pi / 180)
        ..scale(1, scaleY)
        ..translate(-origin.dx, -origin.dy);
    }
    canvas
      ..drawPath(flame, Paint()..color = _flameFill)
      ..restore()
      ..restore();
  }

  /// CSS keyframes at 0 / 50 / 100%: the first half interpolates frame 0→1,
  /// the second 1→2.
  static double _sample(List<double> frames, double t) => t < 0.5
      ? _lerp(frames[0], frames[1], t * 2)
      : _lerp(frames[1], frames[2], (t - 0.5) * 2);

  static (double, double) _sampleFrame(double t) {
    final (aDeg, aScale) = t < 0.5 ? _flameFrames[0] : _flameFrames[1];
    final (bDeg, bScale) = t < 0.5 ? _flameFrames[1] : _flameFrames[2];
    final u = t < 0.5 ? t * 2 : (t - 0.5) * 2;
    return (_lerp(aDeg, bDeg, u), _lerp(aScale, bScale, u));
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(RingtoneTileDiyaPainter old) =>
      old.playing != playing || old.reduceMotion != reduceMotion;
}
