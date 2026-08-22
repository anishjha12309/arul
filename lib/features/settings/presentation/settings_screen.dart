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

/// Settings — profile card, one rows-card, muted logout, demoted delete link,
/// faint legal line. Profile identity
/// comes from the auth state (neutral stand-ins while it loads), edit-name
/// persists via `POST /me/profile`, language drives the app locale, and logout /
/// delete account run the real auth actions before routing back to sign-in.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// English name ↔ locale code for the language sheet (visual labels are the
  /// sheet's own; persistence goes through [LocaleNotifier]).
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

    // Real identity once signed in; neutral stand-ins otherwise. Watch the
    // stream for rebuilds, but READ the service's synchronous state for the
    // value — the broadcast stream does not replay, so emissions from the
    // startup seed land before this screen subscribes and .asData?.value
    // would stay null for the whole session (fallback shown to a signed-in
    // user — the entitlement provider hit the same class of bug).
    ref.watch(authStateStreamProvider);
    final auth = ref.read(authServiceProvider).currentState;
    final authName = auth.displayName?.trim();
    final hasRealName = authName != null && authName.isNotEmpty;
    // Neutral stand-ins while the profile is still loading (settings is only
    // reachable signed in, so this is momentary) — never a fake person.
    final name = hasRealName ? authName : l10n.settingsFallbackName;
    final authEmail = auth.email?.trim();
    final email = (authEmail != null && authEmail.isNotEmpty)
        ? authEmail
        : l10n.settingsFallbackEmail;
    final language = _languageName(ref.watch(localeProvider).languageCode);

    // Reads the persisted opt-in, which the reminders screen keeps reconciled
    // against the real OS permission — so a user who revoked notifications in
    // system settings sees "Off" here, not a stale "On".
    final notificationsOn = ref
        .watch(notificationSettingsProvider)
        .masterEnabled;
    final notificationsSub = notificationsOn
        ? l10n.settingsRemindersSubOn
        : l10n.settingsRemindersSubOff;

    // Premium row subtitle reflects the REAL plan. While it resolves (or if the
    // fetch fails) fall back to the upsell wording — the Manage screen re-reads
    // it anyway, so a wrong-for-a-moment subtitle costs nothing, whereas
    // claiming membership the user doesn't have would.
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
            // The shared tab header band. Settings is a dock BRANCH — never a
            // pushed route — so it gets no back arrow. (A canPop() check here
            // is a trap: while a sub-screen pops back OVER the shell, the
            // departing route is still on the stack, so the arrow flashes in
            // and then vanishes when the transition settles.)
            ArulScreenHeader(title: l10n.settingsTitle),
            Expanded(
              child: ListView(
                // Settings is a dock branch in the shell, and the dock floats
                // OVER it — so the footer owes the capsule its clearance or the
                // policy links and the version sit under it with nothing left
                // to scroll. AppShell.dockClearance already folds in the
                // gesture inset; the extra 24 is the footer's own breathing
                // room, which it had before the dock existed.
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
                    // Brand 'A' while the stand-in shows — 'Y' (from "Your
                    // account") would read as someone else's initial.
                    initial: hasRealName ? authName[0].toUpperCase() : 'A',
                    onEdit: () => _editName(hasRealName ? authName : ''),
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  _RowsCard(
                    rows: [
                      // First row: the plan is the most consequential thing in
                      // Settings, and it was previously not reachable at all.
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
                      // Deliberately NOT a second route to /refer. That screen
                      // is about the user's own rewards; this is the act of
                      // sharing, and making it one tap from Settings rather
                      // than three is the whole point of having it here.
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
                        // Follows the selection, like the sub-label beside it
                        // — a fixed moon on a row reading "Light" was the one
                        // stale thing in the list.
                        icon: themeModeIcon(themeMode),
                        title: l10n.settingsTheme,
                        sub: themeModeLabel(l10n, themeMode),
                        onTap: () => showThemeSheet(context),
                      ),
                      _RowData(
                        icon: Icons.help_outline,
                        title: l10n.settingsNeedHelp,
                        // No longer "& subscription" — that lives in its own row
                        // now, and pointing at a mailto for it would be a lie.
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
                    // Deleting an account is the app's one irreversible act, so
                    // it gets the strongest beat on the way in as well as at the
                    // confirm step.
                    onTapDown: (_) => ArulHaptics.heavy(),
                    onTap: _delete,
                    // Hand-drawn underline. TextDecoration.underline sits hard
                    // on the baseline; this hairline gets 3px of air. The
                    // text's line-height is collapsed to 1.0 first, otherwise
                    // body's 1.5 leading pads the box and drops the rule far
                    // below the glyphs.
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
    // Defensive: unreachable in shipped builds — nothing to persist to in a
    // define-less local run.
    if (!AppConfig.hasBackend) return;
    try {
      // Persists via the Worker (`POST /me/profile`) and reflects reactively
      // through authStateStreamProvider — no local copy to keep in sync.
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
    // Best-effort server logout (refresh-token denylist) + local token clear;
    // never throws for the offline case.
    await ref.read(authControllerProvider.notifier).signOut();
    if (mounted) context.go('/sign-in');
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    // Deleting cancels the UPI mandate server-side and forfeits whatever is left
    // of the paid period — and, because the trial tombstone survives deletion,
    // signing up again does NOT hand back a second free trial. A user who bought
    // premium is entitled to know all of that BEFORE the irreversible tap, so the
    // warning is only shown when it is actually true of them.
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
    // GA4-only (deliberately off the PostHog allow-list): account state lives in
    // Neon, which is exact. These two exist so churn and delete FAILURES are
    // visible in the free, unsampled record — a failing delete is a support
    // problem we would otherwise only hear about by email.
    final analytics = ref.read(analyticsServiceProvider);
    analytics.track('account_delete_confirmed');
    try {
      // Server-side: mandate revoke → tombstone → cascade → refresh denylist.
      // Throws on failure — the account is intact and the session stays.
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
    // A blank email with an identical subject for every user is nearly useless
    // to triage — pre-fill a diagnostics block (version, account, plan) and a
    // prompt so the first reply already has what support needs. Every input
    // degrades gracefully: the providers return null rather than throw, and a
    // signed-in-only screen still guards the identity fields.
    // Recipient read LIVE from the remote app config (brand delta: the
    // documented fallback is support@hsrutility.com via AppConfig).
    final l10n = AppLocalizations.of(context);
    final config = await ref
        .read(appConfigProvider.future)
        .catchError((_) => null);

    // Real installed version (a failed read leaves it blank → "Unknown" below).
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

    // Plan status is the single most common support-triage question for a
    // premium-gated app ("I paid but nothing unlocked") — include it.
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
    // The two prose lines are localized; the diagnostics block below them is
    // deliberately NOT — support triages on those exact labels, and a mail
    // arriving with them in six different scripts is harder to read, not easier.
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

    // launchUrl THROWS (not merely returns false) when no mail client can handle
    // the intent — the normal state of a device with no mail app. Uncaught, that
    // swallows any feedback on tapping "Need help?".
    // mailto: query parts need %20-encoded spaces; Uri(queryParameters:) emits
    // '+', which mail clients render literally — hence the manual _encodeQuery.
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
      // Name the address so the user can still reach us by copying it manually.
      showArulToast(
        context,
        l10n.settingsNoEmailApp(supportEmail),
        kind: ToastKind.error,
      );
    }
  }

  /// `mailto:` query parts need %20 for spaces — [Uri]'s default query encoding
  /// uses '+', which mail clients show literally in the subject/body. Encode
  /// each key/value ourselves (mirrors the Pakiza reference).
  static String _encodeQuery(Map<String, String> params) => params.entries
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('&');
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
    this.icon,
    this.glyph,
    required this.title,
    required this.sub,
    required this.onTap,
  }) : assert(icon != null || glyph != null, 'a row needs one or the other');

  /// A Material icon — the default for the utility rows.
  final IconData? icon;

  /// A custom mark, used where a Material icon would be the wrong voice.
  ///
  /// Exists for the premium row: `workspace_premium` is the same laurel badge a
  /// hundred other apps use for "pro", and every actual premium surface (the
  /// paywall, the sheet, Manage) already carries the brand gopuram. The row is
  /// tinted by the theme, so the glyph builder takes the resolved colour.
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
    // Chevron: dark rgba(250,245,236,.4) / light rgba(43,17,22,.35) have no exact
    // token; darkMuted / lightFaint are the nearest faint neutrals.
    final chevronColor = isDark ? ArulTokens.darkMuted : ArulTokens.lightFaint;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Every settings row presses the same, whether it pushes a screen or
      // opens a picker sheet. The sheet itself stays silent — the tap that
      // opened it has already answered the finger.
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

/// Muted-maroon logout pill (spec): dark bg maroon 35% / border maroon 60% /
/// text #F0C9BA; light bg maroon 8% / border maroon 35% / text maroon.
// ─── Policy footer ────────────────────────────────────────────────────────────

/// The screen's closing block: the two policy links, the DMCA trust badge, and
/// the real installed version.
///
/// It replaced a single faint 'Privacy Policy · Terms · Copyright' line that was
/// not tappable — three promises the user could not act on. The badge is here
/// for the same reason it is in Pakiza: this is a wallpaper app built on
/// devotional artwork, and saying the catalogue is protected is worth the two
/// lines it costs.
class _PolicyFooter extends ConsumerWidget {
  const _PolicyFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The real installed version; blank until the platform read lands, and the
    // row simply stays out until it does rather than flashing a placeholder.
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
        // In-app, never the browser: the policy opens as a pushed screen with
        // its own back arrow (reviewer, 2026-08-12). Nothing to guard against
        // here any more — it is a route, not an intent that can find no
        // handler.
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

/// "DMCA PROTECTED" — a hairline pill in the same language as every other
/// surface chip in the app: card fill, card border, accent glyph.
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
      // Signing out is deliberate but not destructive — a firm press, one step
      // below the delete-account beat.
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

  // Approximation of #F0C9BA built from brand tokens (ivory lightened toward
  // maroon), since the value has no dedicated token.
  static final Color _logoutTextDark = Color.lerp(
    ArulTokens.ivory,
    ArulTokens.maroon,
    0.14,
  )!;
}
