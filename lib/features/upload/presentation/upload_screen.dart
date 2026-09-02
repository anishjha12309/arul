import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_chip.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../../../data/models/wallpaper.dart';
import '../../referral/presentation/share_moment_sheet.dart';
import '../../ringtones/providers/ringtone_catalog_providers.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../providers/upload_provider.dart';

/// Upload-your-content — WALLPAPERS **and** RINGTONES.
///
/// Kind picker, dashed pick zone, optional title, the chosen kind's categories, rights, submit.
///
/// [_pickFile] validates MIME type and size against [UploadConstraints] before accepting a file.
/// Submit stays disabled until a validated file, a category and the rights checkbox are all present.
/// Upload categories are the LIVE ones off the browse catalog, with the shipped six as an
/// offline fallback. A submission still lands only in a moderator-known slug: a catalog chip
/// exists because a PUBLISHED row carries it, so a CMS draft category is never offered.
/// The two kinds do NOT share a list — ringtones drop `temples`, add `others` (CLAUDE.md §5b).
/// The CMS re-checks the slug against the matching set at approve time.
/// A ringtone's `deity` is NEVER collected here — it is classified from LYRICS, not a filename.
/// The row lands with a null deity and degrades to its category's default art.
class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  /// FALLBACK ONLY — what to offer before the catalog has loaded, or offline.
  ///
  /// The live list comes from the catalog now (see [_categories]), so a category added
  /// in the CMS becomes submittable as soon as it is published, with no app release.
  /// These stay because an empty chip row would make the screen unusable on a cold,
  /// offline start; they are the six the app shipped with.
  static const _fallbackWallpaperCategories = [
    'amman',
    'ayyappan',
    'murugan',
    'perumal',
    'sivan',
    'temples',
  ];

  /// NOT the wallpaper list — no `temples`, plus `others` for tracks belonging to no deity.
  static const _fallbackRingtoneCategories = [
    'amman',
    'ayyappan',
    'murugan',
    'others',
    'perumal',
    'sivan',
  ];

  /// 'wallpaper' | 'ringtone' — the submitted `kind`.
  String _kind = 'wallpaper';
  String? _category;
  bool _rightsAccepted = false;

  // Picked file (validated against UploadConstraints before it lands here).
  String? _filePath;
  String? _fileName;
  String? _mimeType;
  int _fileSize = 0;

  final _titleController = TextEditingController();

  bool get _isRingtone => _kind == 'ringtone';

  /// The categories a submission may claim — the LIVE ones, off the catalog.
  ///
  /// Still a closed list, and still only ever moderator-known slugs: a catalog chip
  /// exists because a PUBLISHED row carries it, so a draft category in the CMS is not
  /// offered here either. That was the whole point of the old hardcoded consts, kept —
  /// what changes is that adding a category no longer needs an app release to accept
  /// uploads into it.
  ///
  /// Falls back to the shipped six when the catalog has not arrived, so the screen is
  /// never a dead end offline.
  List<WallpaperCategory> get _categories {
    final live = _isRingtone
        ? ref.watch(ringtoneCategoriesProvider)
        : ref.watch(categoriesProvider);
    if (live.isNotEmpty) return live;
    final slugs = _isRingtone
        ? _fallbackRingtoneCategories
        : _fallbackWallpaperCategories;
    return [
      for (final s in slugs)
        WallpaperCategory(s, s[0].toUpperCase() + s.substring(1)),
    ];
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _filePath != null && _category != null && _rightsAccepted;

  /// Switches kind, dropping the picked file AND the category — both are kind-scoped.
  /// The file would fail the other kind's MIME allow-list, and `Temples`/`Others` exist in one set.
  /// Carrying either across submits a value the CMS then refuses at approve.
  void _selectKind(String kind) {
    if (_kind == kind) return;
    setState(() {
      _kind = kind;
      _category = null;
      _filePath = null;
      _fileName = null;
      _mimeType = null;
      _fileSize = 0;
    });
  }

  /// Picks media for the current kind and validates MIME and size against [UploadConstraints].
  /// Rejects with a toast when it does not fit.
  Future<void> _pickFile() async {
    final l10n = AppLocalizations.of(context);
    // FileType.audio for a ringtone -> the picker cannot offer images or video in the first place.
    // The allow-list below is still the enforcing check — some OEM pickers honour the filter loosely.
    final result = await FilePicker.pickFiles(
      type: _isRingtone ? FileType.audio : FileType.media,
    );
    final file = result?.files.singleOrNull;
    if (file?.path == null || !mounted) return;

    final name = file!.name;
    final mime = UploadConstraints.mimeFromName(name);
    final wallpaperType = mime.startsWith('video/') ? 'live' : 'static';

    if (!UploadConstraints.allowedTypes(_kind, wallpaperType).contains(mime)) {
      showArulToast(
        context,
        // Spelled out per branch, never an interpolated label constant.
        // Such a label is English-only and would sit untranslated inside a translated sentence.
        _isRingtone
            ? l10n.uploadRejectAudio
            : wallpaperType == 'live'
            ? l10n.uploadRejectLive
            : l10n.uploadRejectStatic,
        kind: ToastKind.error,
      );
      return;
    }

    final size = File(file.path!).lengthSync();
    if (size > UploadConstraints.maxBytes(_kind, wallpaperType)) {
      showArulToast(
        context,
        l10n.uploadTooLarge(UploadConstraints.maxLabel(_kind, wallpaperType)),
        kind: ToastKind.error,
      );
      return;
    }

    setState(() {
      _filePath = file.path;
      _fileName = name;
      _mimeType = mime;
      _fileSize = size;
    });
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (!AppConfig.hasBackend) {
      // Define-less local builds only — unreachable in shipped builds, which carry API_BASE_URL.
      showArulToast(context, l10n.uploadComingSoonToast);
      return;
    }
    await ref
        .read(uploadProvider.notifier)
        .submit(
          kind: _kind,
          filePath: _filePath!,
          fileName: _fileName!,
          mimeType: _mimeType!,
          fileSize: _fileSize,
          title: _titleController.text,
          // The Worker and the moderation flow key on the LOWERCASE slug, not the display label.
          // Already a slug off the catalog; lowercased anyway so the value the
          // CMS re-checks at approve can never depend on server casing.
          category: _category!.toLowerCase(),
        );
    if (!mounted) return;
    switch (ref.read(uploadProvider)) {
      case UploadSuccess():
        showArulToast(
          context,
          l10n.uploadSuccessToast,
          kind: ToastKind.success,
        );
        ref.read(uploadProvider.notifier).reset();
        // Someone who just contributed is, by definition, invested enough to tell a friend.
        // Awaited before the pop -> the sheet is never orphaned by this route closing under it.
        await ShareMomentSheet.show(
          context,
          title: l10n.uploadShareMomentTitle,
          body: _isRingtone
              ? l10n.uploadShareMomentBodyRingtone
              : l10n.uploadShareMomentBody,
          source: 'upload_success',
        );
        if (!mounted) return;
        if (context.mounted && context.canPop()) context.pop();
      case UploadError(:final message):
        showArulToast(context, message, kind: ToastKind.error);
        ref.read(uploadProvider.notifier).reset();
      case _:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final textPrimary = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final dashColor = isDark
        ? ArulTokens.goldBorder50
        : const Color.fromRGBO(122, 30, 51, 0.45); // maroon 45%, per spec
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
                    // Kind-neutral — this screen takes both, so the title cannot name one of them.
                    l10n.uploadTitle,
                    style: ArulTokens.screenTitle.copyWith(color: textPrimary),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  // Kind picker — the same ArulChip the categories use, so the two rows read as one.
                  // Changing kind resets the file and the category (_selectKind).
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.uploadKindLabel,
                        style: ArulTokens.rowSub.copyWith(color: labelColor),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ArulChip(
                            label: l10n.uploadKindWallpaper,
                            selected: !_isRingtone,
                            variant: ArulChipVariant.surface,
                            onTap: () => _selectKind('wallpaper'),
                          ),
                          ArulChip(
                            label: l10n.uploadKindRingtone,
                            selected: _isRingtone,
                            variant: ArulChipVariant.surface,
                            onTap: () => _selectKind('ringtone'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Pick zone.
                  GestureDetector(
                    onTapDown: (_) => ArulHaptics.tap(),
                    onTap: _pickFile,
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
                              _isRingtone
                                  ? Icons.library_music
                                  : Icons.add_photo_alternate,
                              size: 32,
                              color: accent,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _fileName ??
                                  (_isRingtone
                                      ? l10n.uploadPickZoneTitleAudio
                                      : l10n.uploadPickZoneTitle),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: ArulTokens.rowTitle.copyWith(
                                color: textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _isRingtone
                                  ? l10n.uploadPickZoneSubAudio
                                  : l10n.uploadPickZoneSub,
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
                            TextSpan(text: '${l10n.uploadTitleLabel} '),
                            TextSpan(
                              text: l10n.uploadTitleOptional,
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
                            hintText: _isRingtone
                                ? l10n.uploadTitleHintRingtone
                                : l10n.uploadTitleHint,
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
                        l10n.uploadCategoryLabel,
                        style: ArulTokens.rowSub.copyWith(color: labelColor),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in _categories)
                            ArulChip(
                              label: c.label,
                              selected: _category == c.slug,
                              variant: ArulChipVariant.surface,
                              onTap: () => setState(() => _category = c.slug),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Rights checkbox.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // A checkbox flips a discrete value — the toggle tick.
                    onTapDown: (_) => ArulHaptics.selection(),
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
                              l10n.uploadRightsCheckbox,
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

                  // Submit — disabled until file, category and rights are all present.
                  // Also disabled while an upload is in flight, for re-entrancy.
                  CtaButton(
                    label: l10n.uploadSubmitCta,
                    busy: ref.watch(uploadProvider) is UploadLoading,
                    fontSize: 15.5,
                    onPressed:
                        _canSubmit &&
                            ref.watch(uploadProvider) is! UploadLoading
                        ? _submit
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _isRingtone
                        ? l10n.uploadFootnoteRingtone
                        : l10n.uploadFootnote,
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
