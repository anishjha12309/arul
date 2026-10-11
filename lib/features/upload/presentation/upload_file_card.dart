import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/motion.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/upload_provider.dart';

/// A file the person chose, as the upload will send it: for a video, the phone's prepared MP4.
class UploadPickedFile {
  const UploadPickedFile({
    required this.path,
    required this.name,
    required this.mime,
    required this.bytes,
    this.durationMs,
  });

  final String path;
  final String name;
  final String mime;
  final int bytes;
  final int? durationMs;
}

/// The pick zone, then the chosen file: a preview, what it is, and Change. While the phone
/// prepares a video, the same card shows its progress and Cancel instead, so the form never jumps.
class UploadFileCard extends StatelessWidget {
  const UploadFileCard({
    super.key,
    required this.kind,
    required this.file,
    required this.preparing,
    required this.enabled,
    required this.onPick,
    required this.onCancel,
  });

  final UploadKind kind;
  final UploadPickedFile? file;

  /// 0–1 while a picked video is being prepared, null otherwise.
  final double? preparing;

  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final picked = file;
    if (picked == null) {
      return _PickZone(kind: kind, enabled: enabled, onPick: onPick);
    }
    return _FileRow(
      kind: kind,
      file: picked,
      preparing: preparing,
      enabled: enabled,
      onPick: onPick,
      onCancel: onCancel,
    );
  }
}

class _PickZone extends StatelessWidget {
  const _PickZone({
    required this.kind,
    required this.enabled,
    required this.onPick,
  });

  final UploadKind kind;
  final bool enabled;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = ArulPalette.of(context);
    final (title, sub, icon) = switch (kind) {
      UploadKind.wallpaper => (
        l10n.uploadPickZoneTitle,
        l10n.uploadPickZoneSub,
        Icons.add_photo_alternate_outlined,
      ),
      UploadKind.ringtone => (
        l10n.uploadPickZoneTitleAudio,
        l10n.uploadPickZoneSubAudio,
        Icons.library_music_outlined,
      ),
      UploadKind.status => (
        l10n.uploadPickZoneTitleVideo,
        l10n.uploadPickZoneSubVideo,
        Icons.video_library_outlined,
      ),
    };
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      identifier: 'arul_upload_pick',
      label: '$title. $sub',
      onTap: enabled ? onPick : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Dead while an upload is in flight: a new pick would delete the very file it reads.
        onTapDown: enabled ? (_) => ArulHaptics.tap() : null,
        onTap: enabled ? onPick : null,
        child: CustomPaint(
          painter: _DashedRectPainter(
            color: p.dash,
            radius: ArulTokens.cardRadius,
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: ArulSpace.s20,
              vertical: ArulSpace.s24,
            ),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
            ),
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.accentTint,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 26, color: p.accent),
                ),
                const SizedBox(height: ArulSpace.s12),
                // ONE line: a wrapping prompt re-laid the whole zone and the form under it.
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: ArulTokens.rowTitle.copyWith(color: p.text),
                ),
                const SizedBox(height: ArulSpace.s4),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: ArulTokens.rowSub.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.kind,
    required this.file,
    required this.preparing,
    required this.enabled,
    required this.onPick,
    required this.onCancel,
  });

  final UploadKind kind;
  final UploadPickedFile file;
  final double? preparing;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = ArulPalette.of(context);
    final progress = preparing;
    final status = progress != null
        ? l10n.uploadPreparingVideo((progress * 100).round().clamp(0, 100))
        : _describe(file);
    return Container(
      padding: const EdgeInsets.all(ArulSpace.s12),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
        border: Border.all(color: p.border, width: ArulTokens.fieldBorderWidth),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _Thumb(kind: kind, file: file, preparing: progress != null),
              const SizedBox(width: ArulSpace.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ArulTokens.rowTitle.copyWith(color: p.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ArulTokens.rowSub.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ArulSpace.s4),
              if (progress != null)
                _CardAction(
                  label: l10n.cancel,
                  identifier: 'arul_upload_prepare_cancel',
                  onTap: onCancel,
                )
              else
                _CardAction(
                  label: l10n.uploadChangeFile,
                  identifier: 'arul_upload_change',
                  onTap: enabled ? onPick : null,
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: ArulSpace.s12),
            _ProgressBar(value: progress),
          ],
        ],
      ),
    );
  }

  /// "JPG · 2.4 MB", "MP4 · 0:28 · 6.1 MB": Latin units and digits, as every size in the app.
  static String _describe(UploadPickedFile file) {
    final type = switch (file.mime) {
      'image/jpeg' => 'JPG',
      'audio/mpeg' => 'MP3',
      'audio/mp4' || 'audio/x-m4a' => 'M4A',
      final mime => mime.split('/').last.toUpperCase(),
    };
    final parts = <String>[type];
    if (file.durationMs case final ms?) {
      final s = (ms / 1000).round();
      parts.add('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}');
    }
    final mb = file.bytes / (1024 * 1024);
    parts.add(
      mb < 1
          ? '${(file.bytes / 1024).ceil()} KB'
          : '${mb.toStringAsFixed(1)} MB',
    );
    return parts.join(' · ');
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.kind,
    required this.file,
    required this.preparing,
  });

  final UploadKind kind;
  final UploadPickedFile file;
  final bool preparing;

  static const double _size = 56;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final radius = BorderRadius.circular(ArulTokens.iconChipRadius);
    if (file.mime.startsWith('image/')) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return ClipRRect(
        borderRadius: radius,
        // The tint holds the square while the pick decodes, so the row never shows a hole.
        child: Container(
          width: _size,
          height: _size,
          color: p.accentTint,
          child: Image.file(
            File(file.path),
            width: _size,
            height: _size,
            fit: BoxFit.cover,
            // Decoded at thumbnail size: a 12-megapixel pick never sits in memory at full size.
            cacheWidth: (_size * dpr).round(),
            errorBuilder: (_, _, _) => _IconTile(
              icon: Icons.image_outlined,
              color: p.accent,
              fill: p.accentTint,
            ),
          ),
        ),
      );
    }
    return _IconTile(
      icon: switch (kind) {
        UploadKind.ringtone => Icons.music_note_rounded,
        _ => preparing ? Icons.hourglass_top_rounded : Icons.play_arrow_rounded,
      },
      color: p.accent,
      fill: p.accentTint,
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.icon,
    required this.color,
    required this.fill,
  });

  final IconData icon;
  final Color color;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _Thumb._size,
      height: _Thumb._size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius),
      ),
      child: Icon(icon, size: 26, color: color),
    );
  }
}

/// Change / Cancel: accent type on a full hit target, a quieter voice than the CTA below.
class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.label,
    required this.identifier,
    required this.onTap,
  });

  final String label;
  final String identifier;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final tap = onTap;
    return Semantics(
      container: true,
      button: true,
      enabled: tap != null,
      identifier: identifier,
      label: label,
      onTap: tap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: tap == null ? null : (_) => ArulHaptics.tap(),
        onTap: tap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: ArulTokens.minHitTarget,
            minWidth: ArulTokens.minHitTarget,
          ),
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: ArulSpace.s8),
              child: Text(
                label,
                style: ArulTokens.button.copyWith(
                  fontSize: 14,
                  color: tap == null ? p.textFaint : p.accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    // The percentage above already speaks it -> the bar itself stays out of TalkBack.
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          child: ColoredBox(
            color: p.accentTint,
            child: AnimatedFractionallySizedBox(
              duration: context.reduceMotion ? Duration.zero : Motion.quick,
              curve: Motion.quickCurve,
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0.0, 1.0),
              heightFactor: 1,
              child: ColoredBox(color: p.accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// 1.5px dashed rounded-rect border for the pick zone — no package is in scope for one.
/// So a small CustomPainter walks the perimeter by [Path.computeMetrics] arc length.
/// It then strokes alternating on and off segments.
class _DashedRectPainter extends CustomPainter {
  const _DashedRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _strokeWidth = 1.5;
  static const double _dashWidth = 6;
  static const double _dashGap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final path = Path()..addRRect(rrect);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + _dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + _dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
