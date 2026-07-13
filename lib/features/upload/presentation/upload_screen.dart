import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/arul_button.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/state_views.dart';
import '../../wallpapers/providers/catalog_providers.dart';

/// Upload-your-content. WALLPAPERS ONLY — Arul has no ringtones, so there is
/// no kind picker; the Worker validates `kind == 'wallpaper'` regardless.
///
/// A category is REQUIRED: approval copies the object to `wallpapers/<category>/`
/// and carries the category onto the row, so a submission without one has
/// nowhere to land.
class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  String? _category;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final categories = ref.watch(categoriesProvider);

    // The category list comes from the catalog, so this screen inherits the
    // catalog's states. It used to watch only `categoriesProvider`, which returns
    // an empty list for BOTH loading and error — so a user who opened Upload while
    // the catalog was still in flight got an *empty* view titled "Couldn't load
    // wallpapers", with no spinner and no retry. Switch on the real state instead.
    final catalog = ref.watch(catalogProvider);
    if (catalog case AsyncLoading()) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.uploadTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (catalog case AsyncError()) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.uploadTitle)),
        body: StateView.error(
          title: l10n.feedErrorTitle,
          message: l10n.feedErrorBody,
          actionLabel: l10n.retry,
          onAction: () => ref.invalidate(catalogProvider),
        ),
      );
    }
    if (categories.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.uploadTitle)),
        body: StateView.empty(
          title: l10n.feedEmptyTitle,
          message: l10n.feedEmptyBody,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.uploadTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(l10n.uploadBody, style: theme.textTheme.bodyMedium),
          const SizedBox(height: Gap.xl),

          Text(l10n.uploadPickCategory, style: theme.textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final c in categories)
                ChoiceChip(
                  label: Text(c.label),
                  selected: _category == c.slug,
                  onSelected: (_) => setState(() => _category = c.slug),
                ),
            ],
          ),

          const SizedBox(height: Gap.xxl),
          ArulButton(
            label: l10n.uploadPickFile,
            icon: Icons.add_photo_alternate_outlined,
            kind: ArulButtonKind.quiet,
            // TODO(phase-4): image_picker -> /media/upload-url -> PUT -> confirm.
            onPressed: _category == null
                ? null
                : () => showArulToast(context, l10n.uploadComingSoon),
          ),
          const SizedBox(height: Gap.lg),
          Text(l10n.uploadSpecNote, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
