import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../theme/arul_tokens.dart';
import '../providers/theme_mode_provider.dart';
import 'confirm_dialog.dart';
import 'edit_name_sheet.dart';
import 'language_sheet.dart';
import 'theme_sheet.dart';

/// Settings — profile card, one rows-card, muted logout, demoted delete link,
/// faint legal line. Copy and mock identity are hardcoded verbatim per the
/// handoff (name, email and the row labels are deliberate constants). The theme
/// row is the only functional control here; language + name are local mock
/// state; logout/delete confirm but their real actions are TODO.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Mock identity (README): "Priya Raman" / "priya.raman@gmail.com" / "P".
  String _name = 'Priya Raman';
  static const _email = 'priya.raman@gmail.com';

  // Visual-only language selection; persists into the row sub-label.
  String _language = 'English';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final headerColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: back arrow + 'Settings' Marcellus 22px.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (context.canPop()) context.pop();
                    },
                    child: Icon(Icons.arrow_back, size: 24, color: headerColor),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Settings',
                    style: ArulTokens.screenTitle.copyWith(color: headerColor),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _ProfileCard(
                    name: _name,
                    email: _email,
                    initial: 'P',
                    onEdit: _editName,
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  _RowsCard(
                    rows: [
                      _RowData(
                        icon: Icons.card_giftcard,
                        title: 'Refer & Earn',
                        sub: 'Earn 30 days free premium',
                        onTap: () => context.push('/refer'),
                      ),
                      _RowData(
                        icon: Icons.translate,
                        title: 'Language',
                        sub: _language,
                        onTap: _pickLanguage,
                      ),
                      _RowData(
                        icon: Icons.dark_mode,
                        title: 'Theme',
                        sub: themeModeLabel(themeMode),
                        onTap: () => showThemeSheet(context),
                      ),
                      _RowData(
                        icon: Icons.help_outline,
                        title: 'Need help?',
                        sub: 'Support & subscription',
                        onTap: _support,
                      ),
                      _RowData(
                        icon: Icons.upload,
                        title: 'Upload your wallpaper',
                        sub: 'Share your own image or video',
                        onTap: () => context.push('/upload'),
                      ),
                    ],
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  _LogoutButton(onTap: _logout),
                  const SizedBox(height: ArulTokens.contentGap),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _delete,
                    child: Text(
                      'Delete account',
                      textAlign: TextAlign.center,
                      style: ArulTokens.body.copyWith(
                        color: isDark
                            ? ArulTokens.darkTextSecondary
                            : ArulTokens.lightSecondary,
                        decoration: TextDecoration.underline,
                        decorationColor: isDark
                            ? ArulTokens.darkTextSecondary
                            : ArulTokens.lightSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Privacy Policy · Terms · Copyright',
                    textAlign: TextAlign.center,
                    style: ArulTokens.caption.copyWith(
                      color: isDark
                          ? ArulTokens.darkFaint
                          : ArulTokens.lightFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editName() async {
    final next = await showEditNameSheet(context, _name);
    if (next != null && next != _name) setState(() => _name = next);
  }

  Future<void> _pickLanguage() async {
    final next = await showLanguageSheet(context, _language);
    if (next != null && next != _language) setState(() => _language = next);
  }

  Future<void> _logout() async {
    final ok = await showArulConfirmDialog(
      context,
      title: 'Logout?',
      message: 'You can sign back in anytime with Google.',
      confirmLabel: 'Logout',
    );
    if (ok == true) {
      // TODO(auth): sign the user out and route to /sign-in.
    }
  }

  Future<void> _delete() async {
    final ok = await showArulConfirmDialog(
      context,
      title: 'Delete account?',
      message: 'This removes your account, favourites and rewards for good.',
      confirmLabel: 'Delete account',
    );
    if (ok == true) {
      // TODO(auth): call account-deletion, then route to /sign-in.
    }
  }

  Future<void> _support() async {
    // launchUrl THROWS (not merely returns false) when no mail client can handle
    // the intent — the normal state of a device with no mail app. Uncaught, that
    // swallows any feedback on tapping "Need help?".
    final uri = Uri(
      scheme: 'mailto',
      path: AppConfig.supportEmail,
      queryParameters: {'subject': 'Arul - Support Request'},
    );
    bool ok;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      showArulToast(
        context,
        'Something went wrong. Please try again.',
        kind: ToastKind.error,
      );
    }
  }
}

/// Silk-gradient profile card — 52px maroon avatar with a gold Marcellus initial,
/// name 16/600 + email 13, and an edit pencil.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.name,
    required this.email,
    required this.initial,
    required this.onEdit,
  });

  final String name;
  final String email;
  final String initial;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final nameColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final emailColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    final pencilColor = isDark ? ArulTokens.gold : ArulTokens.maroon;

    return Container(
      padding: const EdgeInsets.all(ArulTokens.cardPadding16),
      decoration: BoxDecoration(
        gradient: isDark ? ArulTokens.silkDark : ArulTokens.silkLight,
        border: Border.all(
          color: isDark
              ? ArulTokens.silkBorderDark
              : ArulTokens.silkBorderLight,
        ),
        borderRadius: BorderRadius.circular(ArulTokens.cardRadius),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: ArulTokens.maroon,
              shape: BoxShape.circle,
            ),
            child: Text(
              initial,
              style: ArulTokens.priceNumeral.copyWith(color: ArulTokens.gold),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.rowTitle.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: nameColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.rowSub.copyWith(
                    fontSize: 13,
                    color: emailColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onEdit,
            child: Icon(Icons.edit, size: 20, color: pencilColor),
          ),
        ],
      ),
    );
  }
}

class _RowData {
  const _RowData({
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;
}

/// A single rounded card holding all five rows, hairline-divided.
class _RowsCard extends StatelessWidget {
  const _RowsCard({required this.rows});

  final List<_RowData> rows;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final divider = isDark
        ? ArulTokens.rowDividerDark
        : ArulTokens.dividerLight;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight,
        border: Border.all(
          color: isDark
              ? ArulTokens.cardBorderDark09
              : ArulTokens.cardBorderLight,
        ),
        borderRadius: BorderRadius.circular(ArulTokens.rowsCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            _SettingsRow(data: rows[i]),
            if (i < rows.length - 1) Container(height: 1, color: divider),
          ],
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.data});

  final _RowData data;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipBg = isDark
        ? ArulTokens.goldTintFill10
        : ArulTokens.maroonTintFill07;
    final iconColor = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;
    // Chevron: dark rgba(250,245,236,.4) / light rgba(43,17,22,.35) have no exact
    // token; darkMuted / lightFaint are the nearest faint neutrals.
    final chevronColor = isDark ? ArulTokens.darkMuted : ArulTokens.lightFaint;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: data.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: ArulTokens.iconChipSize,
              height: ArulTokens.iconChipSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius),
              ),
              child: Icon(
                data.icon,
                size: ArulTokens.iconChipIconSize,
                color: iconColor,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    style: ArulTokens.rowTitle.copyWith(color: titleColor),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    data.sub,
                    style: ArulTokens.rowSub.copyWith(color: subColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: chevronColor),
          ],
        ),
      ),
    );
  }
}

/// Muted-maroon logout pill (README): dark bg maroon 35% / border maroon 60% /
/// text #F0C9BA; light bg maroon 8% / border maroon 35% / text maroon.
class _LogoutButton extends StatefulWidget {
  const _LogoutButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_LogoutButton> createState() => _LogoutButtonState();
}

class _LogoutButtonState extends State<_LogoutButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Derived from ArulTokens.maroon (base brand token) where no pre-exposed
    // token exists for these exact alphas; light bg is maroonTintFill08 exactly.
    final Color bg = isDark
        ? ArulTokens.maroon.withValues(alpha: _pressed ? 0.5 : 0.35)
        : ArulTokens.maroonTintFill08;
    final Color border = isDark
        ? ArulTokens.maroon.withValues(alpha: 0.6)
        : ArulTokens.maroon.withValues(alpha: 0.35);
    // #F0C9BA has no token and isn't cleanly token-derivable — nearest is a light
    // rose lerp of ivory→maroon. See handoff report (deviation).
    final Color text = isDark ? _logoutTextDark : ArulTokens.maroon;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: Container(
        height: ArulTokens.ctaHeight50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.logout, size: 20, color: text),
            const SizedBox(width: 8),
            Text('Logout', style: ArulTokens.button.copyWith(color: text)),
          ],
        ),
      ),
    );
  }

  // Approximation of #F0C9BA built from brand tokens (ivory lightened toward
  // maroon), since the value has no dedicated token.
  static final Color _logoutTextDark = Color.lerp(
    ArulTokens.ivory,
    ArulTokens.maroon,
    0.14,
  )!;
}
