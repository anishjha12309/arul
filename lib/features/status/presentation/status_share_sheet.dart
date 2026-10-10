import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/status_action_provider.dart';

// Labels and order are the owner's: Groups · WhatsApp · Status · More.
class StatusShareSheet {
  const StatusShareSheet._();

  static Future<StatusShareTarget?> show(BuildContext context) =>
      showArulSheet<StatusShareTarget>(
        context,
        builder: (_) => const _StatusShareSheetBody(),
      );
}

class _StatusShareSheetBody extends StatefulWidget {
  const _StatusShareSheetBody();

  @override
  State<_StatusShareSheetBody> createState() => _StatusShareSheetBodyState();
}

class _StatusShareSheetBodyState extends State<_StatusShareSheetBody> {
  // A second tap lands while the sheet is still animating out -> a second pop would close the
  // screen under it, and a second pick would fire a second intent.
  bool _closed = false;

  void _close([StatusShareTarget? target]) {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop(target);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final targets = <(StatusShareTarget, String, Widget)>[
      (
        StatusShareTarget.groups,
        l10n.statusShareGroups,
        Icon(Icons.groups_rounded, size: _markSize, color: accent),
      ),
      (
        StatusShareTarget.chat,
        l10n.statusShareChat,
        // The brand mark the pill already carries: a person finds WhatsApp by its logo first.
        const Image(
          image: AssetImage('assets/images/whatsapp.webp'),
          width: _markSize,
          height: _markSize,
          filterQuality: FilterQuality.medium,
        ),
      ),
      (
        StatusShareTarget.status,
        l10n.statusShareStatus,
        Icon(Icons.motion_photos_on_rounded, size: _markSize, color: accent),
      ),
      (
        StatusShareTarget.more,
        l10n.statusShareMore,
        Icon(Icons.more_horiz_rounded, size: _markSize, color: accent),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.statusShareTitle,
            style: ArulTokens.sheetTitle.copyWith(
              color: isDark ? ArulTokens.darkText : ArulTokens.lightText,
            ),
          ),
          const SizedBox(height: 16),
          // Equal cells, and ONE type size across them: the row shrinks to its widest word, so a
          // long Tamil label never sits smaller than its neighbours.
          LayoutBuilder(
            builder: (context, constraints) {
              final cellText =
                  (constraints.maxWidth - _cellGap * (targets.length - 1)) /
                      targets.length -
                  _TargetCell.padH * 2;
              final labelStyle = _sharedLabelStyle(context, [
                for (final t in targets) t.$2,
              ], width: cellText);
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < targets.length; i++) ...[
                      if (i > 0) const SizedBox(width: _cellGap),
                      Expanded(
                        child: _TargetCell(
                          label: targets[i].$2,
                          labelStyle: labelStyle,
                          mark: targets[i].$3,
                          identifier: 'arul_status_share_${targets[i].$1.name}',
                          onTap: () => _close(targets[i].$1),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Center(
            child: Semantics(
              identifier: 'arul_status_share_close',
              child: TextButton(
                onPressed: _close,
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  minimumSize: const Size(
                    ArulTokens.minHitTarget * 2,
                    ArulTokens.minHitTarget,
                  ),
                ),
                child: Text(l10n.statusShareClose),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const double _markSize = 28;
  static const double _cellGap = 6;

  static TextStyle _sharedLabelStyle(
    BuildContext context,
    List<String> labels, {
    required double width,
  }) {
    final base = _TargetCell.baseLabelStyle;
    final measured = DefaultTextStyle.of(context).style.merge(base);
    var widest = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: measured),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    if (widest <= width) return base;
    return base.copyWith(fontSize: base.fontSize! * width / widest);
  }
}

class _TargetCell extends StatefulWidget {
  const _TargetCell({
    required this.label,
    required this.labelStyle,
    required this.mark,
    required this.identifier,
    required this.onTap,
  });

  // Four cells share 328 dp at 360 -> every dp of padding comes out of the label's size.
  static const double padH = 4;
  static final TextStyle baseLabelStyle = ArulTokens.body.copyWith(
    fontWeight: FontWeight.w500,
  );

  final String label;
  final TextStyle labelStyle;
  final Widget mark;
  final String identifier;
  final VoidCallback onTap;

  @override
  State<_TargetCell> createState() => _TargetCellState();
}

class _TargetCellState extends State<_TargetCell> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = _pressed
        ? ArulTokens.goldTintFill14
        : (isDark ? ArulTokens.cardBgDark05 : ArulTokens.maroonTintFill07);
    final border = _pressed
        ? ArulTokens.gold
        : (isDark ? ArulTokens.cardBorderDark14 : ArulTokens.cardBorderLight);

    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      identifier: widget.identifier,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Picking a target hands the clip to another app -> a commit, the pill's own weight.
        onTapDown: (_) {
          _setPressed(true);
          ArulHaptics.firm();
        },
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            _TargetCell.padH,
            14,
            _TargetCell.padH,
            12,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius + 4),
            border: Border.all(color: border, width: _pressed ? 1.5 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.mark,
              const SizedBox(height: 8),
              // A guard only: the shared size already fits, but Android's non-linear font scaling can
              // leave a word a hair wide, and a label is never clipped.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: widget.labelStyle.copyWith(
                    color: isDark ? ArulTokens.darkText : ArulTokens.lightText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
