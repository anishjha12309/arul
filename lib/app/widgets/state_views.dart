import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'arul_button.dart';

/// Empty / error surfaces.
///
/// Every async surface in this app must render one of these instead of a blank
/// screen or a spinner that never ends (Definition of Done). They are one widget
/// so that they cannot drift apart visually.
class StateView extends StatelessWidget {
  const StateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  const StateView.empty({
    super.key,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  }) : icon = Icons.auto_awesome_outlined;

  const StateView.error({
    super.key,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  }) : icon = Icons.cloud_off_rounded;

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: ArulColors.gold),
            const SizedBox(height: Gap.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            if (message != null) ...[
              const SizedBox(height: Gap.sm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Gap.xl),
              ArulButton(
                label: actionLabel!,
                onPressed: onAction,
                kind: ArulButtonKind.quiet,
                expand: false,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
