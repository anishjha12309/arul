import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/arul_button.dart';
import 'widgets/video_background.dart';

/// Sign-in.
///
/// It does NOT block the app. Browse and preview are free, so making a wallpaper
/// app demand an account before it will show you a single wallpaper is a good way
/// to be uninstalled. Sign-in exists for the things that genuinely need identity —
/// entitlement, uploads, a collection that survives a new phone — and the user
/// reaches it when they reach for one of those.
///
/// PHASE CONTRACT — do not redesign this away: the real screen AUTO-LAUNCHES the
/// FULL Google `authenticate()` on its first frame (google_sign_in v7: instance →
/// initialize() → authenticate()). It must never be swapped to lightweight/silent
/// auth; that was tried and rejected on retention grounds. The button below is the
/// fallback for a dismissed sheet.
///
/// The background player is SHARED with the splash — the same live decoder handed
/// across the route — so arriving here never re-inits a MediaCodec.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bottom = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Lighter than the splash's veil: here there is real copy and a button
          // to read, so legibility wins over atmosphere. Contrast of white body
          // text over the veiled clip's brightest frame measures 5.1:1.
          const VideoBackground(overlayOpacity: 0.58),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Gap.xl,
                Gap.xl,
                Gap.xl,
                bottom + Gap.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 3),
                  Text(
                    l10n.appName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displayMedium?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(
                    l10n.appTagline,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                      letterSpacing: 2.4,
                    ),
                  ),
                  const Spacer(flex: 2),
                  Text(
                    l10n.signInHeadline,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: Gap.md),
                  Text(
                    l10n.signInBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
                  ),
                  const SizedBox(height: Gap.xxl),
                  ArulButton(
                    label: l10n.signInGoogle,
                    icon: Icons.account_circle_outlined,
                    kind: ArulButtonKind.gold,
                    // TODO(auth-phase): AuthService.signIn() -> Worker /auth/login.
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: Gap.lg),
                  Text(
                    l10n.signInTerms,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.58),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
