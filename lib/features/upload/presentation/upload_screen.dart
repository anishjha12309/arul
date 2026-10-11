import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/motion.dart';
import '../../../app/widgets/arul_form_field.dart';
import '../../../app/widgets/arul_line_icons.dart';
import '../../../app/widgets/arul_pushed_header.dart';
import '../../../app/widgets/arul_segmented.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';
import '../../ringtones/providers/ringtone_catalog_providers.dart';
import '../../share/share_moment_sheet.dart';
import '../../status/providers/status_providers.dart';
import '../../wallpapers/providers/catalog_providers.dart';
import '../data/media_pick_service.dart';
import '../data/video_prep_service.dart';
import '../domain/video_plan.dart';
import '../providers/upload_provider.dart';
import 'upload_category_sheet.dart';
import 'upload_file_card.dart';

/// Upload-your-content — WALLPAPERS, RINGTONES **and** STATUS videos.
/// Upload categories are the LIVE ones off each browse catalog, with the shipped ones as an
/// offline fallback. A submission still lands only in a moderator-known slug: a catalog chip
/// exists because a PUBLISHED row carries it, so a CMS draft category is never offered.
/// A ringtone's `deity` is NEVER collected here — it is classified from LYRICS, not a filename.
/// The row lands with a null deity and degrades to its category's default art.
/// A picked VIDEO is prepared on the phone first (VideoPrepService), so it reaches the Worker's QC
/// already on the video rule.
class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  /// FALLBACK ONLY — what to offer before the catalog has loaded, or offline.
  /// These stay because an empty picker would make the screen unusable on a cold,
  /// offline start; they are the six the app shipped with.
  static const _fallbackWallpaperCategories = [
    'amman',
    'ayyappan',
    'murugan',
    'perumal',
    'sivan',
    'temples',
  ];

  /// NOT the wallpaper list — no `temples`. `others` is retired: nothing may be submitted into it.
  static const _fallbackRingtoneCategories = [
    'amman',
    'ayyappan',
    'murugan',
    'perumal',
    'sivan',
  ];

  /// Status categories are LANGUAGES, the status catalog's own.
  static const _fallbackStatusCategories = ['tamil', 'telugu'];

  UploadKind _kind = UploadKind.wallpaper;
  String? _category;
  bool _rightsAccepted = false;

  UploadPickedFile? _file;

  /// 0–1 while the phone prepares a picked video; null otherwise.
  double? _preparing;

  /// Bumped by every pick, cancel and kind switch -> a preparation that was overtaken never lands.
  int _pickSeq = 0;

  final _titleController = TextEditingController();

  bool _picking = false;

  static const _picker = MediaPickService();

  /// Read once: `dispose` must cancel an export, and a disposed widget's `ref` is gone by then.
  late final VideoPrepService _prep;

  @override
  void initState() {
    super.initState();
    _prep = ref.read(videoPrepServiceProvider);
  }

  /// The categories a submission may claim — the LIVE ones, off the catalog.
  /// Falls back to the shipped ones when the catalog has not arrived, so the screen is
  /// never a dead end offline.
  List<WallpaperCategory> get _categories {
    final live = switch (_kind) {
      UploadKind.wallpaper => ref.watch(categoriesProvider),
      UploadKind.ringtone => ref.watch(ringtoneCategoriesProvider),
      // Only once the Status tab drained it: watching the catalog from here would fetch every
      // status page for a phone that never opened the tab.
      UploadKind.status =>
        ref.exists(statusCatalogProvider)
            ? ref.watch(statusCategoriesProvider)
            : const <WallpaperCategory>[],
    };
    if (live.isNotEmpty) return live;
    final slugs = switch (_kind) {
      UploadKind.wallpaper => _fallbackWallpaperCategories,
      UploadKind.ringtone => _fallbackRingtoneCategories,
      UploadKind.status => _fallbackStatusCategories,
    };
    return [
      for (final s in slugs)
        WallpaperCategory(s, s[0].toUpperCase() + s.substring(1)),
    ];
  }

  @override
  void dispose() {
    if (_preparing != null) unawaited(_prep.cancel());
    _titleController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _file != null &&
      _preparing == null &&
      _category != null &&
      _rightsAccepted;

  /// Switches kind, dropping the picked file AND the category — both are kind-scoped.
  /// The file would fail the other kind's MIME allow-list, and `Temples`/`Tamil` exist in one set.
  /// Carrying either across submits a value the CMS then refuses at approve.
  void _selectKind(UploadKind kind) {
    if (_kind == kind) return;
    _stopPreparing();
    _discardCopy(_file?.path);
    setState(() {
      _kind = kind;
      _category = null;
      _file = null;
      _preparing = null;
    });
  }

  void _stopPreparing() {
    _pickSeq++;
    if (_preparing != null) unawaited(_prep.cancel());
  }

  void _cancelPreparing() {
    _stopPreparing();
    setState(() {
      _file = null;
      _preparing = null;
    });
  }

  /// Deletes a cached pick this screen is done with: rejected, replaced, or dropped with its kind.
  ///
  /// The copies are ours to delete — the native side only sweeps at engine start, so a pick can
  /// never pull a file out from under one still shown, still validating, or mid-upload.
  /// Best effort: a copy that outlives this is cache, and the next engine start sweeps it.
  void _discardCopy(String? path) {
    if (path == null) return;
    unawaited(File(path).delete().then((_) {}, onError: (_) {}));
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    _picking = true;
    try {
      await _pickFileOnce();
    } finally {
      // Not setState: nothing on screen reads it, and the pick sheet is the OS's, not ours.
      _picking = false;
    }
  }

  Future<void> _pickFileOnce() async {
    final l10n = AppLocalizations.of(context);
    final kind = _kind;
    // A per-kind picker -> none can offer another kind's files. The allow-list below is still the
    // enforcing check — some OEM pickers honour the filter loosely.
    PickedMedia? picked;
    try {
      picked = await _picker.pick(switch (kind) {
        UploadKind.wallpaper => MediaPickKind.visual,
        UploadKind.ringtone => MediaPickKind.audio,
        UploadKind.status => MediaPickKind.video,
      });
    } on PlatformException {
      // No picker on the phone, or a provider whose file could not be read -> say so, once.
      if (mounted) {
        showArulToast(context, l10n.errorGenericRetry, kind: ToastKind.error);
      }
      return;
    }
    final file = picked;
    if (file == null || !mounted || kind != _kind) {
      _discardCopy(file?.path);
      return;
    }

    final mime = UploadConstraints.mimeFromName(file.name);
    final isVideo = mime.startsWith('video/');
    // Spelled out per branch, never an interpolated label constant.
    // Such a label is English-only and would sit untranslated inside a translated sentence.
    final reject = switch (kind) {
      UploadKind.ringtone
          when !UploadConstraints.ringtoneTypes.contains(mime) =>
        l10n.uploadRejectAudio,
      UploadKind.status when !isVideo => l10n.uploadRejectLive,
      UploadKind.wallpaper
          when !isVideo &&
              !UploadConstraints.staticWallpaperTypes.contains(mime) =>
        l10n.uploadRejectStatic,
      _ => null,
    };
    if (reject != null) {
      _discardCopy(file.path);
      showArulToast(context, reject, kind: ToastKind.error);
      return;
    }
    if (isVideo) return _prepareVideo(file, kind, mime);

    final size = File(file.path).lengthSync();
    if (size > UploadConstraints.maxBytes(kind.name, 'static')) {
      _discardCopy(file.path);
      showArulToast(
        context,
        l10n.uploadTooLarge(UploadConstraints.maxLabel(kind.name, 'static')),
        kind: ToastKind.error,
      );
      return;
    }

    // Accepted -> the pick it replaces is nobody's now.
    _stopPreparing();
    if (_file?.path != file.path) _discardCopy(_file?.path);
    setState(() {
      _preparing = null;
      _file = UploadPickedFile(
        path: file.path,
        name: file.name,
        mime: mime,
        bytes: size,
      );
    });
  }

  /// A video becomes an upload-ready MP4 on the phone, in the same card, with its progress.
  Future<void> _prepareVideo(
    PickedMedia picked,
    UploadKind kind,
    String mime,
  ) async {
    final l10n = AppLocalizations.of(context);
    _stopPreparing();
    final seq = _pickSeq;
    _discardCopy(_file?.path);
    setState(() {
      _file = UploadPickedFile(
        path: picked.path,
        name: picked.name,
        mime: mime,
        bytes: 0,
      );
      _preparing = 0;
    });

    final PreparedVideo prepared;
    try {
      prepared = await _prep.prepare(
        picked.path,
        kind == UploadKind.status
            ? VideoTarget.status
            : VideoTarget.liveWallpaper,
        onProgress: (v) {
          if (mounted && seq == _pickSeq) setState(() => _preparing = v);
        },
      );
    } on VideoPrepException catch (e) {
      _discardCopy(picked.path);
      if (!mounted || seq != _pickSeq) return;
      setState(() {
        _file = null;
        _preparing = null;
      });
      final message = switch (e.failure) {
        VideoPrepFailure.cancelled => null,
        VideoPrepFailure.noAudio => l10n.uploadVideoNoSound,
        VideoPrepFailure.unsupportedDevice => l10n.uploadVideoNeedsAndroid12,
        VideoPrepFailure.tooLarge => l10n.uploadTooLarge(
          UploadConstraints.maxLabel(kind.name, 'live'),
        ),
        _ => l10n.uploadVideoFailed,
      };
      if (message != null) {
        showArulToast(context, message, kind: ToastKind.error);
      }
      return;
    }

    if (prepared.converted) _discardCopy(picked.path);
    if (!mounted || seq != _pickSeq) {
      _discardCopy(prepared.path);
      return;
    }
    final max = UploadConstraints.maxBytes(kind.name, 'live');
    if (prepared.bytes > max) {
      _discardCopy(prepared.path);
      setState(() {
        _file = null;
        _preparing = null;
      });
      showArulToast(
        context,
        l10n.uploadTooLarge(UploadConstraints.maxLabel(kind.name, 'live')),
        kind: ToastKind.error,
      );
      return;
    }
    setState(() {
      _preparing = null;
      _file = UploadPickedFile(
        path: prepared.path,
        // The upload key and its MIME read the extension -> it names what the bytes now are.
        name: _asMp4(picked.name),
        mime: 'video/mp4',
        bytes: prepared.bytes,
        durationMs: prepared.durationMs,
      );
    });
  }

  static String _asMp4(String name) {
    final dot = name.lastIndexOf('.');
    return '${dot > 0 ? name.substring(0, dot) : name}.mp4';
  }

  Future<void> _chooseCategory(List<WallpaperCategory> categories) async {
    FocusScope.of(context).unfocus();
    final slug = await showUploadCategorySheet(
      context,
      kind: _kind,
      categories: categories,
      selected: _category,
    );
    if (slug == null || !mounted) return;
    setState(() => _category = slug);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final file = _file;
    final category = _category;
    if (file == null || category == null) return;
    if (!AppConfig.hasBackend) {
      // Define-less local builds only — unreachable in shipped builds, which carry API_BASE_URL.
      showArulToast(context, l10n.uploadComingSoonToast);
      return;
    }
    final kind = _kind;
    await ref
        .read(uploadProvider.notifier)
        .submit(
          kind: kind.name,
          filePath: file.path,
          fileName: file.name,
          mimeType: file.mime,
          fileSize: file.bytes,
          title: _titleController.text,
          // The Worker and the moderation flow key on the LOWERCASE slug, not the display label.
          // Already a slug off the catalog; lowercased anyway so the value the
          // CMS re-checks at approve can never depend on server casing.
          category: category.toLowerCase(),
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
          body: switch (kind) {
            UploadKind.wallpaper => l10n.uploadShareMomentBody,
            UploadKind.ringtone => l10n.uploadShareMomentBodyRingtone,
            UploadKind.status => l10n.uploadShareMomentBodyStatus,
          },
          source: 'upload_success',
        );
        if (!mounted) return;
        if (context.mounted && context.canPop()) context.pop();
      case UploadError(:final code):
        // The provider's message is a diagnostic ("Upload URL not received", an HTTP status) ->
        // the user gets a localized line chosen by the Worker's code; the reason stays for logs.
        final message = switch (code) {
          'bad_type' ||
          'too_large' ||
          'corrupt' ||
          'bad_dimensions' ||
          'bad_codec' => l10n.uploadFileRejected,
          'too_many_pending' => l10n.uploadTooManyPending,
          _ => l10n.errorGeneric,
        };
        showArulToast(context, message, kind: ToastKind.error);
        ref.read(uploadProvider.notifier).reset();
      case _:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = ArulPalette.of(context);
    final uploading = ref.watch(uploadProvider) is UploadLoading;
    final categories = _categories;
    String? categoryLabel;
    for (final c in categories) {
      if (c.slug == _category) categoryLabel = c.label;
    }

    return Scaffold(
      backgroundColor: p.surface,
      body: SafeArea(
        child: Column(
          children: [
            ArulPushedHeader(
              // Kind-neutral — this screen takes every kind, so the title cannot name one of them.
              title: l10n.uploadTitle,
              color: p.text,
              identifier: 'arul_upload_back',
              onBack: () => context.pop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  ArulSpace.s16,
                  ArulSpace.s8,
                  ArulSpace.s16,
                  ArulSpace.s32,
                ),
                children: [
                  ArulFieldLabel(l10n.uploadKindLabel),
                  const SizedBox(height: ArulSpace.s8),
                  // A mode, not a value: switching it resets the file and the category below.
                  IgnorePointer(
                    ignoring: uploading,
                    child: ArulSegmented<UploadKind>(
                      selected: _kind,
                      onChanged: _selectKind,
                      segments: [
                        ArulSegment(
                          value: UploadKind.wallpaper,
                          label: l10n.uploadKindWallpaper,
                          glyph: ArulLineGlyph.wallpapers,
                          identifier: 'arul_upload_kind_wallpaper',
                        ),
                        ArulSegment(
                          value: UploadKind.ringtone,
                          label: l10n.uploadKindRingtone,
                          glyph: ArulLineGlyph.ringtones,
                          identifier: 'arul_upload_kind_ringtone',
                        ),
                        ArulSegment(
                          value: UploadKind.status,
                          label: l10n.uploadKindStatus,
                          glyph: ArulLineGlyph.status,
                          identifier: 'arul_upload_kind_status',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: ArulSpace.s16),
                  UploadFileCard(
                    kind: _kind,
                    file: _file,
                    preparing: _preparing,
                    enabled: !uploading,
                    onPick: _pickFile,
                    onCancel: _cancelPreparing,
                  ),
                  const SizedBox(height: ArulSpace.s24),
                  ArulFieldLabel(l10n.uploadCategoryLabel),
                  const SizedBox(height: ArulSpace.s8),
                  ArulSelectField(
                    semanticLabel: l10n.uploadCategoryLabel,
                    placeholder: l10n.uploadPickCategory,
                    value: categoryLabel,
                    identifier: 'arul_upload_category',
                    leading: UploadCategoryGlyph(
                      kind: _kind,
                      slug: _category,
                      color: _category == null ? p.textSecondary : p.accent,
                      size: 26,
                    ),
                    onTap: uploading ? null : () => _chooseCategory(categories),
                  ),
                  const SizedBox(height: ArulSpace.s20),
                  ArulFieldLabel(
                    l10n.uploadTitleLabel,
                    suffix: l10n.uploadTitleOptional,
                  ),
                  const SizedBox(height: ArulSpace.s8),
                  ArulTextField(
                    controller: _titleController,
                    semanticLabel:
                        '${l10n.uploadTitleLabel} ${l10n.uploadTitleOptional}',
                    enabled: !uploading,
                    identifier: 'arul_upload_title',
                    hint: switch (_kind) {
                      UploadKind.wallpaper => l10n.uploadTitleHint,
                      UploadKind.ringtone => l10n.uploadTitleHintRingtone,
                      UploadKind.status => l10n.uploadTitleHintStatus,
                    },
                  ),
                  const SizedBox(height: ArulSpace.s20),
                  _RightsCheck(
                    checked: _rightsAccepted,
                    label: l10n.uploadRightsCheckbox,
                    onChanged: uploading
                        ? null
                        : () => setState(
                            () => _rightsAccepted = !_rightsAccepted,
                          ),
                  ),
                  const SizedBox(height: ArulSpace.s20),
                  CtaButton(
                    label: l10n.uploadSubmitCta,
                    identifier: 'arul_upload_submit',
                    busy: uploading,
                    onPressed: _canSubmit && !uploading ? _submit : null,
                  ),
                  const SizedBox(height: ArulSpace.s12),
                  Text(
                    switch (_kind) {
                      UploadKind.wallpaper => l10n.uploadFootnote,
                      UploadKind.ringtone => l10n.uploadFootnoteRingtone,
                      UploadKind.status => l10n.uploadFootnoteStatus,
                    },
                    textAlign: TextAlign.center,
                    style: ArulTokens.caption.copyWith(color: p.textFaint),
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

/// The rights confirmation: ONE checkbox with its sentence, the box drawn in the form's accent.
class _RightsCheck extends StatelessWidget {
  const _RightsCheck({
    required this.checked,
    required this.label,
    required this.onChanged,
  });

  final bool checked;
  final String label;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return Semantics(
      // Announced as ONE checkbox with its sentence, not a glyph and a paragraph.
      checked: checked,
      enabled: onChanged != null,
      label: label,
      identifier: 'arul_upload_rights',
      onTap: onChanged,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // A checkbox flips a discrete value — the toggle tick.
        onTapDown: onChanged == null ? null : (_) => ArulHaptics.selection(),
        onTap: onChanged,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: ArulTokens.minHitTarget),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: context.reduceMotion ? Duration.zero : Motion.quick,
                curve: Motion.quickCurve,
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: checked ? p.accent : p.field,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: checked ? p.accent : p.textFaint,
                    width: ArulTokens.fieldBorderWidth,
                  ),
                ),
                child: checked
                    ? Icon(Icons.check_rounded, size: 16, color: p.onAccent)
                    : null,
              ),
              const SizedBox(width: ArulSpace.s12),
              Expanded(
                child: Text(
                  label,
                  style: ArulTokens.body.copyWith(color: p.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
