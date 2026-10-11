import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';
import '../../ringtones/presentation/deity_art.dart';
import '../providers/upload_provider.dart';

/// The category picker: one option card per category, the deity's own line art on each, the
/// current choice ringed gold, as on the language sheet. Resolves to the chosen slug, or null when
/// dismissed.
Future<String?> showUploadCategorySheet(
  BuildContext context, {
  required UploadKind kind,
  required List<WallpaperCategory> categories,
  required String? selected,
}) {
  return showArulSheet<String>(
    context,
    builder: (_) =>
        _CategorySheet(kind: kind, categories: categories, selected: selected),
  );
}

class _CategorySheet extends StatelessWidget {
  const _CategorySheet({
    required this.kind,
    required this.categories,
    required this.selected,
  });

  final UploadKind kind;
  final List<WallpaperCategory> categories;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    // Fourteen deities outgrow a short phone -> the list scrolls inside a sheet that stops short of
    // the status bar, so the scrim above it still reads as "tap to close".
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              ArulSpace.s20,
              0,
              ArulSpace.s20,
              ArulSpace.s12,
            ),
            child: Text(
              AppLocalizations.of(context).uploadPickCategory,
              style: ArulTokens.sheetTitle.copyWith(color: p.text),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                ArulSpace.s20,
                0,
                ArulSpace.s20,
                ArulSpace.s24,
              ),
              itemCount: categories.length,
              separatorBuilder: (_, _) => const SizedBox(height: kSheetRowGap),
              itemBuilder: (context, i) {
                final c = categories[i];
                return ArulSheetRow(
                  glyph: (color) => UploadCategoryGlyph(
                    kind: kind,
                    slug: c.slug,
                    color: color,
                  ),
                  title: c.label,
                  selected: c.slug == selected,
                  haptic: ArulHapticStyle.selection,
                  identifier: 'arul_upload_category_${c.slug}',
                  onTap: () => Navigator.of(context).pop(c.slug),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A category's mark, tinted [color]: the deity's line art for a deity category, the gopuram for
/// one with no art of its own, a language glyph for a status category (those are languages).
class UploadCategoryGlyph extends StatelessWidget {
  const UploadCategoryGlyph({
    super.key,
    required this.kind,
    required this.slug,
    required this.color,
    this.size = 30,
  });

  final UploadKind kind;
  final String? slug;
  final Color color;
  final double size;

  /// The catalog's spelling where it differs from the bundled art's slug.
  static const _artAlias = {'narsimha': 'narasimha'};

  @override
  Widget build(BuildContext context) {
    final slug = this.slug;
    if (kind == UploadKind.status) {
      return Icon(Icons.translate_rounded, size: size * 0.7, color: color);
    }
    if (slug == null) {
      return Icon(Icons.category_outlined, size: size * 0.7, color: color);
    }
    final deity = _artAlias[slug] ?? slug;
    return ExcludeSemantics(
      child: Image.asset(
        deityAsset(deity: deity, category: slug),
        width: size,
        height: size,
        color: color,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
