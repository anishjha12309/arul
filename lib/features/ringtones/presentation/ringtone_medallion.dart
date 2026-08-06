/// The ringtone list's signature element: a unique 46×46 medallion per track,
/// drawn rather than downloaded.
///
/// Four layers, bottom to top (design_handoff_ringtones_screen/README.md >
/// "Cover art"): a jewel-tone gradient ground with a hairline rim, a ring of
/// kolam pulli dots woven with a dashed circle, a gold line-work
/// centre motif chosen by the track's deity category, and — only while the
/// track is previewing — a scrim with an oil-lamp diya whose flame sways.
///
/// Procedural on purpose: the catalog ships no cover art for ringtones, and 8
/// static tiles would be 8 more objects to author, host and cache-bust. Every
/// parameter is a pure function of the track's id + category, so a tile looks
/// the same on every device, on every launch, forever ([RingtoneMedallionSpec]).
///
/// ── COLOUR NOTE ────────────────────────────────────────────────────────────
/// The ten gradient grounds, the `#EBD6A3` gold ink, the scrim and the diya's
/// flame colours below are ARTWORK, not UI chrome. They are the palette of one
/// drawing — they have no role anywhere else in the app and must never grow
/// into `ArulTokens`. Every value that *is* chrome (radius, sizes, motion) does
/// come from the tokens.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/arul_tokens.dart';

/// The centre motif, chosen by the track's deity category.
enum RingtoneMotif {
  /// Murugan — the vel (spear) with its peacock eye.
  vel,

  /// Sivan — trishul + damaru.
  trishul,

  /// Amman — lotus over a waterline.
  lotus,

  /// Perumal — shankha (conch) + chakra.
  shankha,

  /// Ayyappan — the 18 sacred steps.
  steps,

  /// The neutral motif — a three-tier gopuram. Drawn for `others`, the category
  /// that holds tracks belonging to no single one of the five deities (Hanuman,
  /// Ganesha, the Madhwa guru Raghavendra). It was originally the `temples`
  /// motif; ringtones no longer use that category, but wallpapers still do.
  gopuram,
}

/// Everything that makes one medallion look like itself.
///
/// Built by [RingtoneMedallionSpec.forRingtone], which is a PURE function of
/// the track's id and category — the catalog carries no art parameters, and the
/// handoff's State Management section says to derive them deterministically
/// from the id when the API does not supply them. Never seed this from a list
/// index: the same track would change costume whenever a category filter
/// re-ordered the list.
@immutable
class RingtoneMedallionSpec {
  const RingtoneMedallionSpec({
    required this.motif,
    required this.groundIndex,
    required this.dotCount,
    required this.rotationDegrees,
  });

  /// Which centre motif is drawn.
  final RingtoneMotif motif;

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

  /// Categories → motifs. Category is free text (CLAUDE.md §5b), so an unknown
  /// one must not crash or all look alike — it falls through to a hashed pick.
  ///
  /// `others` MUST be listed. It is the catch-all for tracks outside the five
  /// deities, and its members are deliberately unlike each other (Hanuman,
  /// Ganesha, Raghavendra) — so the hashed fallback would hand each one a
  /// different deity's emblem, e.g. Murugan's vel on a Ganesha track. That is
  /// worse than neutral art, hence the explicit neutral mapping.
  ///
  /// `temples` is kept for wallpapers' sake and because a stray row must still
  /// render sensibly; no ringtone has used it since 2026-08-06.
  static const Map<String, RingtoneMotif> _motifByCategory = {
    'murugan': RingtoneMotif.vel,
    'sivan': RingtoneMotif.trishul,
    'amman': RingtoneMotif.lotus,
    'perumal': RingtoneMotif.shankha,
    'ayyappan': RingtoneMotif.steps,
    'others': RingtoneMotif.gopuram,
    'temples': RingtoneMotif.gopuram,
  };

  /// The deterministic derivation. Same (id, category) → same spec, always.
  ///
  /// Each parameter is hashed from its OWN salted string rather than from
  /// different bit-slices of one hash. Catalog ids are short and share long
  /// prefixes ("rt-amman-01", "rt-amman-02"); slicing one FNV hash left whole
  /// fields nearly constant across such a set, and a screen of eight tiles that
  /// all chose the same dot count is exactly the sameness this artwork exists
  /// to avoid. Five hashes of a short string per tile is nothing.
  factory RingtoneMedallionSpec.forRingtone({
    required String id,
    required String category,
  }) {
    return RingtoneMedallionSpec(
      motif:
          _motifByCategory[category.toLowerCase()] ??
          RingtoneMotif.values[_hash('$id:motif') %
              RingtoneMotif.values.length],
      groundIndex: _hash('$id:ground') % groundCount,
      dotCount: dotCounts[_hash('$id:dots') % dotCounts.length],
      rotationDegrees: (_hash('$id:rotation') % 360).toDouble(),
    );
  }

  /// FNV-1a with a Murmur3 `fmix32` avalanche on the way out, 32-bit.
  ///
  /// Chosen over [String.hashCode] deliberately: Dart's string hash is not
  /// guaranteed stable across runs or SDK versions, and a tile that silently
  /// re-rolled its artwork on an app update would be a bug nobody could
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
      other is RingtoneMedallionSpec &&
          other.motif == motif &&
          other.groundIndex == groundIndex &&
          other.dotCount == dotCount &&
          other.rotationDegrees == rotationDegrees;

  @override
  int get hashCode =>
      Object.hash(motif, groundIndex, dotCount, rotationDegrees);

  @override
  String toString() =>
      'RingtoneMedallionSpec(${motif.name}, ground: $groundIndex, '
      'dots: $dotCount, rot: $rotationDegrees)';
}

/// One medallion. Pass [playing] to raise the scrim + diya over it.
///
/// The flame's 1100ms sway ([ArulTokens.diyaFlicker]) is driven straight into
/// the painter through `CustomPaint.painter.repaint`, so a playing tile
/// repaints without ever rebuilding a widget — and the ticker only runs while
/// this row is the playing one. `MediaQuery.disableAnimations` holds the flame
/// still with the glow parked at 0.4, per the handoff.
class RingtoneMedallion extends StatefulWidget {
  const RingtoneMedallion({
    super.key,
    required this.spec,
    required this.playing,
    this.size = defaultSize,
  });

  final RingtoneMedallionSpec spec;
  final bool playing;
  final double size;

  /// The handoff's tile size, and the authoring viewBox of every path.
  static const double defaultSize = 46;

  @override
  State<RingtoneMedallion> createState() => _RingtoneMedallionState();
}

class _RingtoneMedallionState extends State<RingtoneMedallion>
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant RingtoneMedallion old) {
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
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: RingtoneMedallionPainter(
          spec: widget.spec,
          playing: widget.playing,
          reduceMotion: _reduceMotion,
          flicker: _flicker,
        ),
      ),
    );
  }
}

/// Paints one medallion. Public so a test can assert what it was handed.
class RingtoneMedallionPainter extends CustomPainter {
  RingtoneMedallionPainter({
    required this.spec,
    required this.playing,
    required this.reduceMotion,
    required this.flicker,
  }) : super(repaint: playing && !reduceMotion ? flicker : null);

  final RingtoneMedallionSpec spec;
  final bool playing;
  final bool reduceMotion;

  /// 0 → 1 → 0 over two [ArulTokens.diyaFlicker] beats. Read only while
  /// [playing] and motion is allowed.
  final Animation<double> flicker;

  // ── Artwork palette (see the COLOUR NOTE at the top of this file) ─────────

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

  /// One warm gold ink for every line on every tile.
  static const Color _ink = Color(0xFFEBD6A3);

  /// The now-playing scrim.
  static const Color _scrim = Color.fromRGBO(14, 6, 8, 0.66);

  /// The diya: glow core, glow falloff, bowl fill, flame.
  static const Color _glowCore = Color(0xFFF4DFA8);
  static const Color _glowEdge = Color(0xFFD4A017);
  static const Color _bowlFill = Color.fromRGBO(212, 160, 23, 0.35);
  static const Color _flameFill = Color(0xFFF6E3AE);

  /// The authoring viewBox: everything below is in 46-unit coordinates.
  static const double _vb = RingtoneMedallion.defaultSize;
  static const Offset _centre = Offset(23, 23);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _vb);

    _ground(canvas);
    _kolam(canvas);
    _motif(canvas);
    if (playing) _diya(canvas);

    canvas.restore();
  }

  // ── 1. Ground ────────────────────────────────────────────────────────────

  void _ground(Canvas canvas) {
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
  }

  // ── 2. Kolam ring ────────────────────────────────────────────────────────

  void _kolam(Canvas canvas) {
    const ringRadius = 15.0;
    final dot = Paint()..color = _ink.withValues(alpha: 0.5);
    final step = 2 * math.pi / spec.dotCount;
    final start = spec.rotationDegrees * math.pi / 180;
    for (var i = 0; i < spec.dotCount; i++) {
      final a = start + i * step;
      canvas.drawCircle(
        _centre + Offset(math.cos(a), math.sin(a)) * ringRadius,
        1.05,
        dot,
      );
    }
    // The woven ring is drawn on EVERY tile. It used to be a per-track coin
    // flip, which meant two rows of the same list wore structurally different
    // artwork — some a ring of dots, some a ring of dots inside a dashed
    // circle — and the list read as if each tile had been styled separately.
    // Pakiza's medallions get their variety the other way round: one fixed
    // skeleton, and only its PARAMETERS permute. Same rule here now, so the
    // eight tiles are eight settings of one drawing.
    _dashedCircle(
      canvas,
      radius: ringRadius,
      on: 2,
      off: 3.6,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.85
        ..color = _ink.withValues(alpha: 0.3),
    );
  }

  /// `stroke-dasharray` has no Flutter equivalent, so the ring is drawn as its
  /// on-segments. The period is re-derived from the rounded segment count so
  /// the dashes close evenly instead of leaving a seam at 3 o'clock.
  void _dashedCircle(
    Canvas canvas, {
    required double radius,
    required double on,
    required double off,
    required Paint paint,
  }) {
    final circumference = 2 * math.pi * radius;
    final count = math.max(1, (circumference / (on + off)).round());
    final step = 2 * math.pi / count;
    final sweep = (on / circumference) * 2 * math.pi;
    final box = Rect.fromCircle(center: _centre, radius: radius);
    for (var i = 0; i < count; i++) {
      canvas.drawArc(box, i * step, sweep, false, paint);
    }
  }

  // ── 3. Centre motif ──────────────────────────────────────────────────────

  Paint _stroke([double opacity = 1]) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.15
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = _ink.withValues(alpha: opacity);

  void _motif(Canvas canvas) {
    switch (spec.motif) {
      case RingtoneMotif.vel:
        _vel(canvas);
      case RingtoneMotif.trishul:
        _trishul(canvas);
      case RingtoneMotif.lotus:
        _lotus(canvas);
      case RingtoneMotif.shankha:
        _shankha(canvas);
      case RingtoneMotif.steps:
        _steps(canvas);
      case RingtoneMotif.gopuram:
        _gopuram(canvas);
    }
  }

  /// Shaft, diamond head, peacock eye.
  void _vel(Canvas canvas) {
    final s = _stroke();
    canvas
      ..drawLine(const Offset(23, 32), const Offset(23, 20), s)
      ..drawPath(
        _closedPolygon(const [
          Offset(23, 12.4),
          Offset(26, 19.4),
          Offset(23, 21.4),
          Offset(20, 19.4),
        ]),
        s,
      )
      ..drawCircle(const Offset(23, 27), 2.4, _stroke(0.85))
      ..drawCircle(const Offset(23, 27), 0.75, Paint()..color = _ink);
  }

  /// Trishul + damaru.
  void _trishul(Canvas canvas) {
    final s = _stroke();
    canvas
      ..drawLine(const Offset(23, 33), const Offset(23, 13), s)
      ..drawLine(const Offset(17.6, 17), const Offset(17.6, 12.2), s)
      ..drawLine(const Offset(28.4, 17), const Offset(28.4, 12.2), s)
      ..drawLine(const Offset(17.6, 17), const Offset(28.4, 17), s)
      ..drawPath(
        _polyline(const [
          Offset(20.4, 24.6),
          Offset(25.6, 24.6),
          Offset(20.4, 30.4),
          Offset(25.6, 30.4),
        ]),
        _stroke(0.85),
      );
  }

  /// Three petals over a waterline.
  void _lotus(Canvas canvas) {
    final s = _stroke();
    canvas
      ..drawPath(
        Path()
          ..moveTo(23, 31)
          ..cubicTo(20.4, 27, 20.8, 20.6, 23, 16.4)
          ..cubicTo(25.2, 20.6, 25.6, 27, 23, 31),
        s,
      )
      ..drawPath(
        Path()
          ..moveTo(23, 31)
          ..cubicTo(18.6, 29.4, 15.8, 25.4, 15.2, 20.8)
          ..cubicTo(19, 22.4, 22, 26.4, 23, 31),
        s,
      )
      ..drawPath(
        Path()
          ..moveTo(23, 31)
          ..cubicTo(27.4, 29.4, 30.2, 25.4, 30.8, 20.8)
          ..cubicTo(27, 22.4, 24, 26.4, 23, 31),
        s,
      );
    final water = _stroke(0.7);
    canvas
      ..drawLine(const Offset(23, 31), const Offset(13.6, 31), water)
      ..drawLine(const Offset(23, 31), const Offset(32.4, 31), water);
  }

  /// Chakra with four spokes, conch beside it.
  void _shankha(Canvas canvas) {
    final s = _stroke();
    canvas.drawCircle(const Offset(29.2, 24), 5, s);

    final spoke = _stroke(0.7);
    canvas
      ..drawLine(const Offset(24.2, 24), const Offset(34.2, 24), spoke)
      ..drawLine(const Offset(29.2, 19), const Offset(29.2, 29), spoke)
      ..drawLine(const Offset(25.7, 20.5), const Offset(32.7, 27.5), spoke)
      ..drawLine(const Offset(32.7, 20.5), const Offset(25.7, 27.5), spoke)
      ..drawPath(
        Path()
          ..moveTo(18.8, 16.6)
          ..cubicTo(14.4, 18.6, 13.6, 25.4, 16.6, 28.6)
          ..cubicTo(18.6, 30.8, 20.8, 29, 19.8, 26.6)
          ..cubicTo(19, 24.6, 17.8, 22.4, 18.8, 16.6)
          ..close(),
        s,
      );
  }

  /// The 18 sacred steps, with the finial dot at the top.
  void _steps(Canvas canvas) {
    canvas
      ..drawPath(
        _polyline(const [
          Offset(12.6, 32.4),
          Offset(17.2, 32.4),
          Offset(17.2, 28.8),
          Offset(21.8, 28.8),
          Offset(21.8, 25.2),
          Offset(26.4, 25.2),
          Offset(26.4, 21.6),
          Offset(31, 21.6),
          Offset(31, 18),
          Offset(34.4, 18),
        ]),
        _stroke(),
      )
      ..drawCircle(
        const Offset(32.6, 15.6),
        1.1,
        Paint()..color = _ink.withValues(alpha: 0.9),
      );
  }

  /// Three stacked tiers plus a finial.
  void _gopuram(Canvas canvas) {
    final s = _stroke();
    canvas
      ..drawPath(
        _closedPolygon(const [
          Offset(12.4, 33),
          Offset(14.6, 26.6),
          Offset(31.4, 26.6),
          Offset(33.6, 33),
        ]),
        s,
      )
      ..drawPath(
        _polyline(const [
          Offset(15.4, 26.6),
          Offset(17.4, 20.6),
          Offset(28.6, 20.6),
          Offset(30.6, 26.6),
        ]),
        s,
      )
      ..drawPath(
        _polyline(const [
          Offset(18.2, 20.6),
          Offset(20, 15.4),
          Offset(26, 15.4),
          Offset(27.8, 20.6),
        ]),
        s,
      )
      ..drawLine(const Offset(23, 15.4), const Offset(23, 12), s);
  }

  // ── 4. Now-playing diya ──────────────────────────────────────────────────

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

  void _diya(Canvas canvas) {
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

  // ── Path helpers ─────────────────────────────────────────────────────────

  static Path _polyline(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  static Path _closedPolygon(List<Offset> points) => _polyline(points)..close();

  @override
  bool shouldRepaint(RingtoneMedallionPainter old) =>
      old.spec != spec ||
      old.playing != playing ||
      old.reduceMotion != reduceMotion;
}
