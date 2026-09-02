import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/shell/app_shell.dart';
import '../../../app/widgets/arul_screen_header.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../app/widgets/gopuram_mark.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/package_info_provider.dart';
import '../../../data/models/subscription_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../theme/arul_tokens.dart';
import '../../auth/providers/auth_providers.dart';
import '../../legal/presentation/policy_screen.dart';
import '../../notifications/providers/notification_providers.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../referral/data/tell_a_friend.dart';
import '../providers/theme_mode_provider.dart';
import 'confirm_dialog.dart';
import 'edit_name_sheet.dart';
import 'language_sheet.dart';
import 'theme_sheet.dart';

/// Settings — profile card, one rows-card, muted logout, demoted delete link, faint legal line.
///
/// Identity comes from the auth state, with neutral stand-ins while it loads.
/// Edit-name persists via `POST /me/profile`, and language drives the app locale.
/// Logout and delete-account run the real auth actions before routing back to sign-in.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// English name ↔ locale code for the language sheet — the visual labels are the sheet's own.
  /// Persistence goes through [LocaleNotifier].
  static const _languageCodes = {
    'English': 'en',
    'Tamil': 'ta',
    'Telugu': 'te',
    'Kannada': 'kn',
    'Malayalam': 'ml',
    'Hindi': 'hi',
  };

  String _languageName(String code) => _languageCodes.entries
      .firstWhere(
        (e) => e.value == code,
        orElse: () => _languageCodes.entries.first,
      )
      .key;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final themeMode = ref.watch(themeModeProvider);

    // The broadcast stream does not REPLAY -> a startup-seed emission lands before this subscribes.
    // `.asData?.value` would then stay null all session, showing a signed-in user the fallback.
    // So WATCH the stream for rebuilds, but READ the service's synchronous state for the value.
    ref.watch(authStateStreamProvider);
    final auth = ref.read(authServiceProvider).currentState;
    final authName = auth.displayName?.trim();
    final hasRealName = authName != null && authName.isNotEmpty;
    // Neutral stand-ins while the profile loads — momentary, and never a fake person.
    final name = hasRealName ? authName : l10n.settingsFallbackName;
    final authEmail = auth.email?.trim();
    final email = (authEmail != null && authEmail.isNotEmpty)
        ? authEmail
        : l10n.settingsFallbackEmail;
    final language = _languageName(ref.watch(localeProvider).languageCode);

    // Reads the persisted opt-in, which the reminders screen reconciles against the OS permission.
    // So a user who revoked notifications in system settings sees "Off" here, not a stale "On".
    final notificationsOn = ref
        .watch(notificationSettingsProvider)
        .masterEnabled;
    final notificationsSub = notificationsOn
        ? l10n.settingsRemindersSubOn
        : l10n.settingsRemindersSubOff;

    // The premium subtitle reflects the REAL plan; while it resolves, fall back to the upsell.
    // The Manage screen re-reads it anyway -> a momentary understatement costs nothing.
    // Claiming a membership the user does not have would.
    final entitlement = ref.watch(entitlementDetailProvider).asData?.value;
    final premiumSub = switch (entitlement?.subscription?.status) {
      _ when entitlement?.isPremium != true => l10n.settingsPremiumSubLocked,
      SubscriptionStatus.trialing => l10n.settingsPremiumSubTrial,
      SubscriptionStatus.cancelled => l10n.settingsPremiumSubCancelled,
      _ => l10n.settingsPremiumSubActive,
    };

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The shared tab header band. Settings is a dock BRANCH, never a push -> no back arrow.
            // A canPop() check is a trap: a departing sub-screen is still on the stack mid-pop.
            // The arrow would flash in and vanish as the transition settles.
            ArulScreenHeader(title: l10n.settingsTitle),
            Expanded(
              child: ListView(
                // The dock floats OVER this branch -> the footer owes the capsule its clearance.
                // Without it the policy links and version sit under the dock with nothing to scroll.
                // AppShell.dockClearance folds in the gesture inset; the extra 24 is the footer's own.
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  24 + AppShell.dockClearance(context),
                ),
                children: [
                  _ProfileCard(
                    name: name,
                    email: email,
                    // Brand 'A' while the stand-in shows — 'Y' would read as someone else's initial.
                    initial: hasRealName ? authName[0].toUpperCase() : 'A',
                    onEdit: () => _editName(hasRealName ? authName : ''),
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  _RowsCard(
                    rows: [
                      // First row — the plan is the most consequential thing in Settings.
                      _RowData(
                        glyph: (color) => GopuramMark(size: 19, color: color),
                        title: l10n.premiumBrandTitle,
                        sub: premiumSub,
                        onTap: () => context.push('/premium?source=settings'),
                      ),
                      _RowData(
                        icon: Icons.card_giftcard,
                        title: l10n.referTitle,
                        sub: l10n.settingsReferSub,
                        onTap: () => context.push('/refer'),
                      ),
                      // Deliberately NOT a second route to /refer — that screen is about rewards.
                      // This is the ACT of sharing, one tap from Settings rather than three.
                      _RowData(
                        icon: Icons.ios_share_rounded,
                        title: l10n.settingsTellFriend,
                        sub: l10n.settingsTellFriendSub,
                        onTap: () =>
                            tellAFriend(context, ref, source: 'settings'),
                      ),
                      _RowData(
                        icon: Icons.notifications_active_outlined,
                        title: l10n.remindersTitle,
                        sub: notificationsSub,
                        onTap: () => context.push('/settings/notifications'),
                      ),
                      _RowData(
                        icon: Icons.translate,
                        title: l10n.settingsLanguage,
                        sub: language,
                        onTap: () => _pickLanguage(language),
                      ),
                      _RowData(
                        // Follows the selection — a fixed moon on a row reading "Light" was stale.
                        icon: themeModeIcon(themeMode),
                        title: l10n.settingsTheme,
                        sub: themeModeLabel(l10n, themeMode),
                        onTap: () => showThemeSheet(context),
                      ),
                      _RowData(
                        icon: Icons.help_outline,
                        title: l10n.settingsNeedHelp,
                        // Subscription has its own row now -> pointing a mailto at it would be a lie.
                        sub: l10n.settingsNeedHelpSub,
                        onTap: _support,
                      ),
                      _RowData(
                        icon: Icons.upload,
                        title: l10n.settingsUpload,
                        sub: l10n.settingsUploadSub,
                        onTap: () => context.push('/upload'),
                      ),
                    ],
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  _LogoutButton(onTap: _logout),
                  const SizedBox(height: ArulTokens.contentGap),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Deleting is the app's one irreversible act -> the strongest beat, twice.
                    onTapDown: (_) => ArulHaptics.heavy(),
                    onTap: _delete,
                    // TextDecoration.underline sits hard on the baseline -> a hand-drawn 3px rule.
                    // Line-height collapses to 1.0 first, or body's 1.5 leading drops the rule away.
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.settingsDeleteAccount,
                            textAlign: TextAlign.center,
                            style: ArulTokens.body.copyWith(
                              height: 1,
                              color: isDark
                                  ? ArulTokens.darkTextSecondary
                                  : ArulTokens.lightSecondary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            height: 1,
                            width: 98,
                            color: isDark
                                ? ArulTokens.darkTextSecondary
                                : ArulTokens.lightSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _PolicyFooter(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editName(String current) async {
    final l10n = AppLocalizations.of(context);
    final next = await showEditNameSheet(context, current);
    if (next == null || next.trim().isEmpty || next.trim() == current) return;
    // Unreachable in shipped builds — a define-less local run has nothing to persist to.
    if (!AppConfig.hasBackend) return;
    try {
      // Persists via `POST /me/profile` and reflects through authStateStreamProvider — no local copy.
      await ref.read(authControllerProvider.notifier).updateDisplayName(next);
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException && e.message.isNotEmpty
          ? e.message
          : l10n.errorGenericRetry;
      showArulToast(context, message, kind: ToastKind.error);
    }
  }

  Future<void> _pickLanguage(String current) async {
    final next = await showLanguageSheet(context, current);
    final code = _languageCodes[next];
    if (code == null) return;
    await ref.read(localeProvider.notifier).setLocale(Locale(code));
  }

  Future<void> _logout() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showArulConfirmDialog(
      context,
      title: l10n.settingsLogoutConfirmTitle,
      message: l10n.settingsLogoutConfirmBody,
      confirmLabel: l10n.settingsLogout,
    );
    if (ok != true) return;
    // Best-effort server logout plus a local token clear — never throws for the offline case.
    await ref.read(authControllerProvider.notifier).signOut();
    if (mounted) context.go('/sign-in');
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    // Deleting cancels the mandate server-side and forfeits whatever is left of the paid period.
    // The trial tombstone survives deletion -> signing up again is NOT a second free trial.
    // A payer is entitled to know that BEFORE the tap -> warn, but only when it is true of them.
    final entitlement = ref.read(entitlementDetailProvider).asData?.value;
    final hasPremium = entitlement?.isPremium ?? false;

    final ok = await showArulConfirmDialog(
      context,
      title: l10n.settingsDeleteConfirmTitle,
      message: hasPremium
          ? l10n.settingsDeleteConfirmBodyPremium
          : l10n.settingsDeleteConfirmBody,
      confirmLabel: l10n.settingsDeleteAccount,
    );
    if (ok != true) return;
    // GA4-only, deliberately off the PostHog allow-list — account state lives in Neon, exactly.
    // These exist so churn and delete FAILURES show in the free, unsampled record.
    // A failing delete is otherwise a support problem we only hear about by email.
    final analytics = ref.read(analyticsServiceProvider);
    analytics.track('account_delete_confirmed');
    try {
      // Server-side: mandate revoke → tombstone → cascade → refresh denylist.
      // Throws on failure -> the account is intact and the session stays.
      await ref.read(authControllerProvider.notifier).deleteAccount();
      if (mounted) context.go('/sign-in');
    } catch (e) {
      analytics.track(
        'account_delete_failed',
        properties: {'error': e.toString()},
      );
      if (!mounted) return;
      final message = e is ApiException && e.message.isNotEmpty
          ? e.message
          : l10n.errorGenericRetry;
      showArulToast(context, message, kind: ToastKind.error);
    }
  }

  Future<void> _support() async {
    // A blank email with an identical subject for every user is nearly useless to triage.
    // So pre-fill version, account and plan, plus a prompt -> the first reply already has them.
    // Every input degrades gracefully: the providers return null rather than throw.
    // The recipient is read LIVE from the remote app config, falling back through AppConfig.
    final l10n = AppLocalizations.of(context);
    final config = await ref
        .read(appConfigProvider.future)
        .catchError((_) => null);

    // Real installed version — a failed read leaves it blank, printing "Unknown" below.
    var version = '';
    try {
      final info = await ref.read(packageInfoProvider.future);
      version = '${info.version} (${info.buildNumber})';
    } catch (_) {
      // Leave blank; the body prints "Unknown".
    }

    final auth = ref.read(authServiceProvider).currentState;
    final userId = auth.userId;
    final email = auth.email?.trim();

    // "I paid but nothing unlocked" is the commonest triage question -> include the plan status.
    final entitlement = ref.read(entitlementDetailProvider).asData?.value;
    final plan = entitlement?.isPremium != true
        ? 'Free'
        : switch (entitlement?.subscription?.status) {
            SubscriptionStatus.trialing => 'Trial',
            SubscriptionStatus.cancelled => 'Premium (auto-renew off)',
            _ => 'Premium',
          };

    final supportEmail = config?.supportEmail ?? AppConfig.supportEmail;
    final versionText = version.isEmpty ? 'Unknown' : version;

    // Blank lines give the user room to type ABOVE the diagnostics block.
    // The prose lines are localized; the diagnostics block deliberately is NOT.
    // Support triages on those exact labels — six scripts would be harder to read, not easier.
    final body = StringBuffer()
      ..writeln(l10n.settingsSupportEmailPrompt)
      ..writeln()
      ..writeln()
      ..writeln('— — — — — — — — — —')
      ..writeln(l10n.settingsSupportEmailDetails)
      ..writeln('App: Arul $versionText')
      ..writeln(
        'Account: ${(email != null && email.isNotEmpty) ? email : 'Not signed in'}',
      )
      ..writeln('Plan: $plan')
      ..write(
        'User ID: ${(userId != null && userId.isNotEmpty) ? userId : 'Not signed in'}',
      );

    // launchUrl THROWS, not merely returns false, when no mail client can take the intent.
    // Uncaught, that swallows all feedback on tapping "Need help?".
    // `mailto:` needs %20 spaces and `Uri(queryParameters:)` emits '+' -> the manual _encodeQuery.
    final uri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: _encodeQuery({
        'subject': version.isEmpty
            ? 'Arul Support Request'
            : 'Arul Support Request — v$version',
        'body': body.toString(),
      }),
    );

    ref
        .read(analyticsServiceProvider)
        .track(
          'support_email_opened',
          properties: {'has_user': userId != null},
        );

    bool ok;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      // Name the address, so the user can still reach us by copying it manually.
      showArulToast(
        context,
        l10n.settingsNoEmailApp(supportEmail),
        kind: ToastKind.error,
      );
    }
  }

  /// [Uri]'s default query encoding uses '+', which mail clients show literally in the subject.
  /// `mailto:` needs %20 -> encode each key and value here instead.
  static String _encodeQuery(Map<String, String> params) => params.entries
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('&');
}

/// Silk-gradient profile card — a 52px maroon avatar with a gold initial, name, email, edit pencil.
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
    this.icon,
    this.glyph,
    required this.title,
    required this.sub,
    required this.onTap,
  }) : assert(icon != null || glyph != null, 'a row needs one or the other');

  /// A Material icon — the default for the utility rows.
  final IconData? icon;

  /// A custom mark, for where a Material icon would be the wrong voice.
  ///
  /// `workspace_premium` is the laurel badge a hundred other apps use for "pro".
  /// Every real premium surface already carries the brand gopuram -> the row does too.
  /// The row is tinted by the theme, so the glyph builder takes the resolved colour.
  final Widget Function(Color color)? glyph;

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
    // The chevron's exact alphas have no token — darkMuted and lightFaint are the nearest neutrals.
    final chevronColor = isDark ? ArulTokens.darkMuted : ArulTokens.lightFaint;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Every settings row presses the same, push or sheet.
      // The sheet itself stays silent — the tap that opened it already answered the finger.
      onTapDown: (_) => ArulHaptics.tap(),
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
              child:
                  data.glyph?.call(iconColor) ??
                  Icon(
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

/// The screen's closing block — the two policy links, the DMCA trust badge, the installed version.
///
/// A faint untappable 'Privacy Policy · Terms · Copyright' line was three promises nobody could act on.
/// This is a wallpaper app built on devotional artwork -> saying the catalogue is protected earns its space.
class _PolicyFooter extends ConsumerWidget {
  const _PolicyFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The real installed version — blank until the platform read lands, and the row stays out.
    final info = ref.watch(packageInfoProvider).asData?.value;

    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 4,
          children: [
            _FooterLink(label: l10n.settingsPrivacy, doc: PolicyDoc.privacy),
            Text(
              '·',
              style: ArulTokens.body.copyWith(
                color: isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint,
              ),
            ),
            _FooterLink(label: l10n.settingsTerms, doc: PolicyDoc.terms),
            Text(
              '·',
              style: ArulTokens.body.copyWith(
                color: isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint,
              ),
            ),
            _FooterLink(label: l10n.settingsRefund, doc: PolicyDoc.refund),
          ],
        ),
        const SizedBox(height: 14),
        const _DmcaBadge(),
        if (info != null) ...[
          const SizedBox(height: 12),
          Text(
            'Version: ${info.version} (${info.buildNumber})',
            style: ArulTokens.caption.copyWith(
              color: isDark ? ArulTokens.darkFaint : ArulTokens.lightFaint,
            ),
          ),
        ],
      ],
    );
  }
}

class _FooterLink extends StatelessWidget {
  const _FooterLink({required this.label, required this.doc});

  final String label;
  final PolicyDoc doc;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      link: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => ArulHaptics.tap(),
        // In-app, NEVER the browser — the policy is a pushed screen with its own back arrow.
        // A route, not an intent that can find no handler, so there is nothing to guard.
        onTap: () => context.push(doc.route),
        child: Text(
          label,
          style: ArulTokens.body.copyWith(
            fontWeight: FontWeight.w500,
            color: isDark ? ArulTokens.gold : ArulTokens.maroon,
          ),
        ),
      ),
    );
  }
}

/// "DMCA PROTECTED" — a hairline pill in every other surface chip's language: fill, border, glyph.
class _DmcaBadge extends StatelessWidget {
  const _DmcaBadge();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: isDark ? ArulTokens.cardBgDark05 : ArulTokens.cardBgLight,
        borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        border: Border.all(
          color: isDark
              ? ArulTokens.cardBorderDark14
              : ArulTokens.cardBorderLight,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 16, color: accent),
          const SizedBox(width: 8),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'DMCA ',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                    color: isDark ? ArulTokens.ivory : ArulTokens.lightText,
                  ),
                ),
                TextSpan(
                  text: 'PROTECTED',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.7,
                    color: isDark
                        ? ArulTokens.darkTextSecondary
                        : ArulTokens.lightSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Muted-maroon logout pill — dark: maroon-35% ground, maroon-60% border, `#F0C9BA` text.
/// Light: maroon-8% ground, maroon-35% border, maroon text.
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
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Derived from ArulTokens.maroon where no token exposes these alphas; light is maroonTintFill08.
    final Color bg = isDark
        ? ArulTokens.maroon.withValues(alpha: _pressed ? 0.5 : 0.35)
        : ArulTokens.maroonTintFill08;
    final Color border = isDark
        ? ArulTokens.maroon.withValues(alpha: 0.6)
        : ArulTokens.maroon.withValues(alpha: 0.35);
    // `#F0C9BA` has no token and is not cleanly derivable — nearest is a light ivory→maroon lerp.
    final Color text = isDark ? _logoutTextDark : ArulTokens.maroon;

    return GestureDetector(
      // Signing out is deliberate but not destructive — a firm press, one step below delete.
      onTapDown: (_) {
        ArulHaptics.firm();
        setState(() => _pressed = true);
      },
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
            Text(
              l10n.settingsLogout,
              style: ArulTokens.button.copyWith(color: text),
            ),
          ],
        ),
      ),
    );
  }

  // Approximation of `#F0C9BA` from brand tokens — ivory lightened toward maroon; no token exists.
  static final Color _logoutTextDark = Color.lerp(
    ArulTokens.ivory,
    ArulTokens.maroon,
    0.14,
  )!;
}
