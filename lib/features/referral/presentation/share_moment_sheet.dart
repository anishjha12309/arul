import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/arul_sheet.dart';
import '../../../app/widgets/cta_button.dart';
import '../../../theme/arul_tokens.dart';
import '../data/tell_a_friend.dart';

/// A short, dismissible invitation to pass Arul on, shown at the two moments a
/// user has just been given something: their subscription starting, and their
/// own wallpaper going in for review.
///
/// A sheet rather than an action on the toast, because [showArulToast] has no
/// action button on purpose — since Flutter 3.38 a SnackBar with an action stops
/// auto-dismissing, which turns a transient toast into a permanent bar. Anything
/// asking for a decision belongs here.
///
/// It never blocks: dismissing is one tap, and the caller continues either way.
class ShareMomentSheet {
  const ShareMomentSheet._();

  /// Shows the sheet and resolves once it closes — whether the user shared or
  /// dismissed. Callers `await` it before popping their own screen, so the sheet
  /// is never orphaned by a route disappearing beneath it.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String body,
    required String source,
  }) async {
    await showArulSheet<void>(
      context,
      builder: (_) => _Body(title: title, body: body, source: source),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.title, required this.body, required this.source});

  final String title;
  final String body;
  final String source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final bodyColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: ArulTokens.sheetTitle.copyWith(color: titleColor)),
          const SizedBox(height: 10),
          Text(
            body,
            style: ArulTokens.rowSub.copyWith(color: bodyColor, height: 1.5),
          ),
          const SizedBox(height: 20),
          CtaButton(
            label: 'Share Arul',
            icon: Icons.share_rounded,
            onPressed: () {
              final nav = Navigator.of(context);
              // The NAVIGATOR's context, not this sheet's: popping unmounts
              // everything below, and tellAFriend still has to resolve
              // AppLocalizations off a live element.
              final host = nav.context;
              // Close FIRST — the share hands off to another app, and leaving
              // the sheet behind means the user returns to a modal they have to
              // dismiss before they can do anything else.
              nav.pop();
              unawaited(tellAFriend(host, ref, source: source));
            },
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: accent),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}
