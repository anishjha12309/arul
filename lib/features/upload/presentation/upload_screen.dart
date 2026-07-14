import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/arul_chip.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../theme/arul_tokens.dart';

/// Upload-your-content. WALLPAPERS ONLY — Arul has no ringtones, so there is
/// no kind picker; the Worker validates `kind == 'wallpaper'` regardless.
///
/// DESIGN-ONLY pass (design_handoff_arul spec, "Upload screen"): dashed pick
/// zone, optional title field, EXACTLY the 6 fixed categories (no "All"),
/// rights checkbox, single green submit. No real file picking yet — the pick
/// zone tap is a TODO and submit-enabled state is driven by local mock state
/// (category + rights) only, per the design-handoff instructions. Category
/// labels are hardcoded consts for this pass — the live screen re-wires them
/// from `categoriesProvider` (see git history) once the picker lands.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  static const _categories = [
    'Amman',
    'Ayyappan',
    'Murugan',
    'Perumal',
    'Sivan',
    'Temples',
  ];

  String? _category;
  bool _rightsAccepted = false;

  final _titleController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  bool get _canSubmit => _category != null && _rightsAccepted;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final dashColor = isDark
        ? ArulTokens.goldBorder50
        : const Color.fromRGBO(122, 30, 51, 0.45); // maroon 45%, README
    final pickZoneFill = isDark ? null : ArulTokens.cardBgLight;
    final labelColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final placeholderColor = isDark
        ? ArulTokens.darkFaint
        : ArulTokens.lightFaint;
    final fieldFill = isDark ? ArulTokens.cardBgDark05 : ArulTokens.cardBgLight;
    final fieldBorder = isDark
        ? ArulTokens.cardBorderDark14
        : ArulTokens.maroonBorder18;
    final pickSubLabel = isDark
        ? ArulTokens.darkMuted
        : ArulTokens.lightSecondary;
    final rightsTextColor = isDark
        ? ArulTokens.darkBodyWarm
        : ArulTokens.lightBody;
    final footnoteColor = isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: Icon(Icons.arrow_back, color: textPrimary),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Upload wallpaper',
                    style: ArulTokens.screenTitle.copyWith(color: textPrimary),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  // Pick zone.
                  GestureDetector(
                    // TODO(phase-4): image_picker -> /media/upload-url -> PUT -> confirm.
                    onTap: () =>
                        showArulToast(context, 'Upload is coming soon.'),
                    child: CustomPaint(
                      painter: _DashedRectPainter(
                        color: dashColor,
                        radius: ArulTokens.cardRadius,
                      ),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 34,
                        ),
                        decoration: BoxDecoration(
                          color: pickZoneFill,
                          borderRadius: BorderRadius.circular(
                            ArulTokens.cardRadius,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.add_photo_alternate,
                              size: 32,
                              color: accent,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Choose an image or video',
                              textAlign: TextAlign.center,
                              style: ArulTokens.rowTitle.copyWith(
                                color: textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Portrait, 1080×2400 or larger',
                              textAlign: TextAlign.center,
                              style: ArulTokens.rowSub.copyWith(
                                color: pickSubLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Title (optional).
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: ArulTokens.rowSub.copyWith(color: labelColor),
                          children: [
                            const TextSpan(text: 'Title '),
                            TextSpan(
                              text: '(optional)',
                              style: TextStyle(color: placeholderColor),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 50,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: fieldFill,
                          borderRadius: BorderRadius.circular(
                            ArulTokens.inputRadius,
                          ),
                          border: Border.all(color: fieldBorder),
                        ),
                        alignment: Alignment.centerLeft,
                        child: TextField(
                          controller: _titleController,
                          style: TextStyle(fontSize: 14.5, color: textPrimary),
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText: 'e.g. Meenakshi at dusk',
                            hintStyle: TextStyle(
                              fontSize: 14.5,
                              color: placeholderColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Category.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Category',
                        style: ArulTokens.rowSub.copyWith(color: labelColor),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in _categories)
                            ArulChip(
                              label: c,
                              selected: _category == c,
                              variant: ArulChipVariant.surface,
                              onTap: () => setState(() => _category = c),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Rights checkbox.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _rightsAccepted = !_rightsAccepted),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 4,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _rightsAccepted
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 22,
                            color: _rightsAccepted
                                ? accent
                                : (isDark
                                      ? ArulTokens.darkFaint
                                      : ArulTokens.lightFaint),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'I own the rights to this content or have '
                              'permission to share it',
                              style: ArulTokens.caption.copyWith(
                                fontSize: 13,
                                color: rightsTextColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // NOTE: spec says submit is disabled until file + category +
                  // rights; this design-only pass has no real file picker, so
                  // it's gated on category + rights alone (deviation, tracked
                  // above via the TODO on the pick zone).
                  CtaButton(
                    label: 'Submit for review',
                    fontSize: 15.5,
                    onPressed: _canSubmit
                        ? () => showArulToast(context, 'Upload is coming soon.')
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Approved wallpapers appear in the feed with your name',
                    textAlign: TextAlign.center,
                    style: ArulTokens.caption.copyWith(color: footnoteColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1.5px dashed rounded-rect border for the pick zone. README calls for a
/// dashed border with no dedicated package in scope, so it's a small
/// CustomPainter: walk the rounded-rect perimeter as a [Path.computeMetrics]
/// arc-length and stroke alternating on/off segments.
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
