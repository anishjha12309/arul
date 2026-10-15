import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_button.dart';
import '../../../app/widgets/arul_dialog.dart';
import '../../../app/widgets/arul_form_field.dart';
import '../../../app/widgets/arul_pressable.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/button_kind.dart' show ArulButtonPalette;
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/status_persona_provider.dart';

/// The user's photo and name on statuses, after Shubh's photo sheet: one place to pick the photo,
/// edit the name and switch either off.
class StatusPersonaSheet {
  const StatusPersonaSheet._();

  static const nameMaxLength = 30;

  static Future<void> show(BuildContext context) => showArulSheet<void>(
    context,
    builder: (_) => const _PersonaBody(),
  );

  /// Android 11 and older: the export would crash there, so an Arul dialog says so instead (owner).
  static Future<void> showUnsupported(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return showArulDialog<void>(
      context,
      barrierLabel: l10n.statusPersonaOldTitle,
      builder: (context) => ArulDialogCard(
        title: l10n.statusPersonaOldTitle,
        message: l10n.statusPersonaOldBody,
        confirm: ArulDialogButton(
          label: l10n.statusPersonaOldOk,
          filled: true,
          identifier: 'arul_status_persona_old_ok',
          onTap: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}

class _PersonaBody extends ConsumerStatefulWidget {
  const _PersonaBody();

  @override
  ConsumerState<_PersonaBody> createState() => _PersonaBodyState();
}

class _PersonaBodyState extends ConsumerState<_PersonaBody> {
  late final TextEditingController _name;
  late final String _initialName;
  bool _picking = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initialName = ref.read(statusPersonaNameProvider) ?? '';
    _name = TextEditingController(text: _initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _picking = true);
    try {
      await ref.read(statusPersonaProvider.notifier).pickPhoto();
    } catch (_) {
      if (mounted) {
        showArulToast(context, l10n.statusPersonaPhotoFailed, kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _done() async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isNotEmpty && name != _initialName) {
      setState(() => _saving = true);
      try {
        await ref.read(statusPersonaProvider.notifier).saveName(name);
      } catch (_) {
        if (mounted) {
          setState(() => _saving = false);
          showArulToast(context, l10n.statusPersonaNameFailed, kind: ToastKind.error);
        }
        return;
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = ArulPalette.of(context);
    final persona = ref.watch(statusPersonaProvider).value ?? const StatusPersona();
    final notifier = ref.read(statusPersonaProvider.notifier);
    final photo = persona.photo;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.statusPersonaTitle,
            style: ArulTokens.sheetTitle.copyWith(color: p.text),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.statusPersonaBody,
            style: ArulTokens.body.copyWith(color: p.textMuted),
          ),
          const SizedBox(height: 18),
          // Stacked, not side by side: at 320 dp and large text a button beside the disc was cut.
          Center(child: _PhotoDisc(photo: photo)),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final en = lookupAppLocalizations(const Locale('en'));
              final (label, english) = photo == null
                  ? (l10n.statusPersonaChoosePhoto, en.statusPersonaChoosePhoto)
                  : (l10n.statusPersonaChangePhoto, en.statusPersonaChangePhoto);
              return ArulButton(
                // ArulButton pads its label 24 either side; the icon and its gap take 28 more.
                label: _fitsOrEnglish(context, label, english, constraints.maxWidth - 76),
                kind: ArulButtonKind.quiet,
                icon: Icons.add_a_photo_outlined,
                busy: _picking,
                identifier: 'arul_status_persona_pick',
                onPressed: _picking ? null : _pick,
              );
            },
          ),
          if (photo != null)
            ArulPressable(
              identifier: 'arul_status_persona_remove',
              onTap: _picking ? null : notifier.removePhoto,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  l10n.statusPersonaRemovePhoto,
                  textAlign: TextAlign.center,
                  style: ArulTokens.body.copyWith(color: p.textSecondary),
                ),
              ),
            ),
          const SizedBox(height: 18),
          ArulFieldLabel(l10n.statusPersonaNameLabel),
          const SizedBox(height: 6),
          ArulTextField(
            controller: _name,
            semanticLabel: l10n.statusPersonaNameLabel,
            maxLength: StatusPersonaSheet.nameMaxLength,
            identifier: 'arul_status_persona_name',
          ),
          const SizedBox(height: 8),
          _SwitchRow(
            label: l10n.statusPersonaShowPhoto,
            value: persona.showPhoto,
            identifier: 'arul_status_persona_show_photo',
            onChanged: notifier.setShowPhoto,
          ),
          _SwitchRow(
            label: l10n.statusPersonaShowName,
            value: persona.showName,
            identifier: 'arul_status_persona_show_name',
            onChanged: notifier.setShowName,
          ),
          const SizedBox(height: 14),
          ArulButton(
            label: l10n.statusPersonaDone,
            busy: _saving,
            identifier: 'arul_status_persona_done',
            onPressed: _saving ? null : _done,
          ),
        ],
      ),
    );
  }
}

/// The photo as it will sit on a clip: round, gold-ringed; a quiet silhouette before one is picked.
class _PhotoDisc extends StatelessWidget {
  const _PhotoDisc({required this.photo});

  final ui.Image? photo;

  static const _size = 76.0;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final photo = this.photo;
    // Gold rings a picked photo, as the export does; empty, the disc takes the pick button's light fill
    // (the translucent tile over gold read as a solid mustard blob).
    final (fill, _) = ArulButtonKind.quiet.colors(Theme.of(context).colorScheme);
    return Container(
      width: _size,
      height: _size,
      padding: photo == null ? null : const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: photo == null ? fill : ArulTokens.gold,
        border: photo == null ? Border.all(color: p.border) : null,
      ),
      child: ClipOval(
        child: photo == null
            ? Icon(Icons.person_rounded, size: 40, color: p.textFaint)
            : RawImage(image: photo, fit: BoxFit.cover),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.identifier,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final String identifier;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return ArulPressable(
      identifier: identifier,
      selected: value,
      onTap: () => onChanged(!value),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: ArulTokens.rowTitle.copyWith(color: p.text),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeThumbColor: ArulTokens.thumbOn,
              activeTrackColor: p.accent,
            ),
          ],
        ),
      ),
    );
  }
}

/// [label] when it fits [room] at the phone's text scale, else plain English (owner: an overflowing
/// translation reads in English, never shortened or cut).
String _fitsOrEnglish(BuildContext context, String label, String english, double room) {
  final style = DefaultTextStyle.of(context).style.merge(Theme.of(context).textTheme.labelLarge);
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final fits = painter.width.ceilToDouble() + 2 <= room;
  painter.dispose();
  return fits ? label : english;
}
