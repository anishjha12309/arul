import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../data/models/wallpaper.dart';
import '../../../theme/arul_tokens.dart';
import '../data/wallpaper_apply_service.dart';
import 'viewer_media.dart';
import 'wallpaper_tile.dart';

/// Where to put a STATIC wallpaper (Spec > Apply sheet).
///
/// Three equal cards — Home / Lock / Both, defaulting to Both — and a single green CTA.
/// Selecting a card only moves the selection; the CTA commits the target.
/// LIVE wallpapers never reach here — Android's own chooser asks the same question and decides.
/// The [wallpaper] is carried in so its own still heads the sheet: the thing being placed stays on
/// screen across the open instead of the sheet rising over an unrelated surface.
/// `ApplySheet.show(context, wallpaper: w)` resolves to the picked target, or null when dismissed.
class ApplySheet {
  const ApplySheet._();

  static Future<ApplyTarget?> show(
    BuildContext context, {
    required Wallpaper wallpaper,
  }) {
    return showArulSheet<ApplyTarget>(
      context,
      builder: (_) => _ApplySheetBody(wallpaper: wallpaper),
    );
  }
}

class _ApplySheetBody extends StatefulWidget {
  const _ApplySheetBody({required this.wallpaper});

  final Wallpaper wallpaper;

  @override
  State<_ApplySheetBody> createState() => _ApplySheetBodyState();
}

class _ApplySheetBodyState extends State<_ApplySheetBody> {
  ApplyTarget _target = ApplyTarget.both; // Spec: default Both

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Every word on this sheet is an ARB key -> it renders in the user's language, not the author's.
    final cards = <(ApplyTarget, IconData, String, String)>[
      (
        ApplyTarget.home,
        Icons.home_rounded,
        l10n.applyTargetHome,
        'arul_apply_home',
      ),
      (
        ApplyTarget.lock,
        Icons.lock_rounded,
        l10n.applyTargetLock,
        'arul_apply_lock',
      ),
      (
        ApplyTarget.both,
        Icons.smartphone_rounded,
        l10n.applyTargetBoth,
        'arul_apply_both',
      ),
    ];
    return Padding(
      // Spec: pad 18 20 24; the grabber + its padding come from ArulSheet.
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _WallpaperThumb(wallpaper: widget.wallpaper),
              // 14, as after every other 40px chip in the app (`ArulSheetRow`).
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  l10n.applyTargetTitle,
                  style: ArulTokens.sheetTitle.copyWith(
                    color: isDark ? ArulTokens.darkText : ArulTokens.lightText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // A translated label can wrap where English sits on one line -> the three cards share the
          // tallest one's height, so a two-line Tamil card never leaves its neighbours short.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _TargetCard(
                      icon: cards[i].$2,
                      label: cards[i].$3,
                      identifier: cards[i].$4,
                      selected: _target == cards[i].$1,
                      onTap: () => setState(() => _target = cards[i].$1),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          CtaButton(
            label: l10n.apply,
            identifier: 'arul_apply_confirm',
            icon: Icons.wallpaper_rounded,
            height: ArulTokens.ctaHeight50,
            fontSize: 15.5,
            // The commit press of the sheet -> the same weight as the feed's Apply pill.
            haptic: ArulHapticStyle.firm,
            onPressed: () => Navigator.of(context).pop(_target),
          ),
        ],
      ),
    );
  }
}

/// The wallpaper being placed, at the head of the sheet.
///
/// Reads the EXACT provider the card under the sheet is already painting — [Wallpaper.posterUrl]
/// at [WallpaperTile.decodeWidthFor] — so this is an image-cache hit and NOT a second decode.
/// Decode width is part of the cache key: asking for a thumbnail-sized one would re-decode the
/// wallpaper and store a third copy of it, which is the cost this head exists to avoid.
/// Downsampling the 200dp entry into a 40px box happens on the GPU, and is free.
/// [ViewerMedia.cropAlignment] for the same reason the poster and the texture share it — a
/// differently cropped still reads as another picture, not as the one under the sheet.
///
/// **A miss paints the well and nothing else — this widget never LOADS.** The card that opened the
/// sheet is still mounted and still painting that entry, so a miss means the cache was evicted
/// under pressure, and the answer to memory pressure is not to fetch the image again. It is also
/// what keeps the sheet off the network: [CachedNetworkImageProvider] would reach the cache manager
/// and, under `flutter test`, path_provider — which has no plugin there.
class _WallpaperThumb extends StatelessWidget {
  const _WallpaperThumb({required this.wallpaper});

  final Wallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = ResizeImage.resizeIfNeeded(
      WallpaperTile.decodeWidthFor(context),
      null,
      CachedNetworkImageProvider(wallpaper.posterUrl(AppConfig.cdnBaseUrl)),
    );
    // Both links of the chain hand back a SynchronousFuture -> `then` runs before the next line.
    Object? key;
    provider.obtainKey(ImageConfiguration.empty).then((k) => key = k);
    final decoded =
        key != null && PaintingBinding.instance.imageCache.containsKey(key!);

    return ClipRRect(
      borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius),
      child: SizedBox(
        width: ArulTokens.iconChipSize,
        height: ArulTokens.iconChipSize,
        child: ColoredBox(
          color: isDark ? ArulTokens.cardBgDark05 : ArulTokens.maroonTintFill07,
          child: decoded
              ? Image(
                  image: provider,
                  fit: BoxFit.cover,
                  alignment: ViewerMedia.cropAlignment,
                  // Decoration beside the title -> announced by nothing, and never a broken glyph.
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              : null,
        ),
      ),
    );
  }
}

/// One target card — r16, a 26px icon over a 13px label.
/// Selected is a gold 1.5px border, gold-tint fill and gold icon, in both themes.
/// Unselected follows the app theme — ivory-tint on dark, maroon-tint on light.
class _TargetCard extends StatelessWidget {
  const _TargetCard({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.identifier,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Stable accessibility id (`Semantics(identifier:)`): announced to nobody, so it is free at
  /// the UI layer and survives every locale.
  /// Never announced and never visible — see that folder's README for the list.
  final String identifier;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unselectedFill = isDark
        ? ArulTokens.cardBgDark05
        : ArulTokens.maroonTintFill07;
    final unselectedBorder = isDark
        ? ArulTokens.cardBorderDark14
        : ArulTokens.cardBorderLight;
    final unselectedIcon = isDark
        ? ArulTokens.ivory
        : ArulTokens.lightSecondary;
    final labelColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;

    return Semantics(
      container: true,
      button: true,
      label: label,
      identifier: identifier,
      selected: selected,
      excludeSemantics: true,
      child: GestureDetector(
        // A card picks between values -> the lightest tick, on press-DOWN, like every other picker.
        onTapDown: (_) => ArulHaptics.selection(),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 13),
          decoration: BoxDecoration(
            color: selected ? ArulTokens.goldTintFill14 : unselectedFill,
            borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius + 4),
            border: Border.all(
              color: selected ? ArulTokens.gold : unselectedBorder,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 26,
                color: selected ? ArulTokens.gold : unselectedIcon,
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: ArulTokens.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: labelColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
