import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_icon_tap.dart';
import '../../../app/widgets/arul_pressable.dart';
import '../../../app/widgets/arul_pushed_header.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/api/api_client.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/package_info_provider.dart';
import '../../../data/models/subscription_model.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../theme/arul_palette.dart';
import '../../../theme/arul_tokens.dart';
import '../../auth/providers/auth_providers.dart';
import '../../legal/presentation/policy_screen.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../../push/providers/push_providers.dart';
import '../../quick_bar/providers/quick_bar_providers.dart';
import '../../share/tell_a_friend.dart';
import '../providers/theme_mode_provider.dart';
import 'confirm_dialog.dart';
import 'edit_name_sheet.dart';
import 'help_sheet.dart';
import 'language_sheet.dart';
import 'theme_sheet.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _quickBarBusy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = ArulPalette.of(context);
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
    // The EFFECTIVE language, so a phone-language default shows here as what the user is reading.
    final languageCode = ref.watch(localeProvider).languageCode;
    final language = appLanguageName(languageCode);
    // The row shows the autonym (தமிழ், not "Tamil") — the word a speaker recognises; the sheet
    // still trades in the English NAME, which is why `language` stays what it was.
    final languageShown = appLanguageNativeNames[languageCode] ?? language;
    final quickBarOn = ref.watch(quickBarSettingProvider) == true;

    return Scaffold(
      backgroundColor: p.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Pushed from the header gear on every tab -> back pops to whichever tab opened it.
            ArulPushedHeader(
              title: l10n.settingsTitle,
              color: p.text,
              identifier: 'arul_settings_back',
            ),
            Expanded(
              child: ListView(
                // Edge-to-edge with no dock over it -> the footer clears the gesture bar itself.
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  24 + MediaQuery.viewPaddingOf(context).bottom,
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
                      _RowData(
                        icon: Icons.ios_share_rounded,
                        title: l10n.settingsTellFriend,
                        identifier: 'arul_settings_tell_friend',
                        sub: l10n.settingsTellFriendSub,
                        onTap: () =>
                            tellAFriend(context, ref, source: 'settings'),
                      ),
                      _RowData(
                        icon: Icons.translate,
                        title: l10n.settingsLanguage,
                        identifier: 'arul_settings_language',
                        sub: languageShown,
                        onTap: () => _pickLanguage(language),
                      ),
                      _RowData(
                        // Follows the selection — a fixed moon on a row reading "Light" was stale.
                        icon: themeModeIcon(themeMode),
                        title: l10n.settingsTheme,
                        identifier: 'arul_settings_theme',
                        sub: themeModeLabel(l10n, themeMode),
                        onTap: () => showThemeSheet(context),
                      ),
                      if (ref.watch(quickBarAllowedProvider))
                        _RowData(
                          icon: Icons.notifications_active_outlined,
                          title: l10n.settingsQuickBar,
                          identifier: 'arul_settings_quick_bar',
                          sub: l10n.settingsQuickBarSub,
                          onTap: () => _setQuickBar(!quickBarOn),
                          trailing: _QuickBarSwitch(
                            on: quickBarOn,
                            onChanged: _setQuickBar,
                          ),
                        ),
                      _RowData(
                        icon: Icons.help_outline,
                        title: l10n.settingsNeedHelp,
                        identifier: 'arul_settings_help',
                        // FIXED, not state-aware (owner's call): the sheet behind it is where a
                        // stuck user goes, whatever their plan.
                        sub: l10n.settingsNeedHelpSub,
                        onTap: _needHelp,
                      ),
                      _RowData(
                        icon: Icons.upload,
                        title: l10n.settingsUpload,
                        identifier: 'arul_settings_upload',
                        sub: l10n.settingsUploadSub,
                        onTap: () => context.push('/upload'),
                      ),
                    ],
                  ),
                  const SizedBox(height: ArulTokens.contentGap),
                  Semantics(
                    container: true,
                    identifier: 'arul_settings_logout',
                    child: _LogoutButton(onTap: _logout),
                  ),
                  // Delete lives in the Need help? sheet now -> one home, and it stops being a
                  // demoted link the eye finds on the way past the version number.
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

  /// Turning it on must end with a bar the person can see: ask once if never asked, otherwise send
  /// them to the screen that blocks it. The resume re-sync posts it once they allow it there.
  Future<void> _setQuickBar(bool on) async {
    // A second tap before the row rebuilds would report the same choice twice.
    if (_quickBarBusy) return;
    _quickBarBusy = true;
    try {
      await _applyQuickBar(on);
    } finally {
      _quickBarBusy = false;
    }
  }

  Future<void> _applyQuickBar(bool on) async {
    await ref.read(quickBarSettingProvider.notifier).set(on, via: 'settings');
    if (!on || !mounted) return;
    final bar = ref.read(quickBarChannelProvider);
    var status = await bar.status();
    if (!mounted || status == null || status.visible) return;
    final permission = ref.read(pushPermissionProvider);
    if (!permission.alreadyPrompted) {
      await permission.promptOnce();
      if (!mounted) return;
      status = await bar.status();
      if (!mounted || status == null || status.visible) {
        ref.invalidate(quickBarSyncProvider);
        return;
      }
    }
    await bar.openSettings();
  }

  Future<void> _pickLanguage(String current) async {
    final next = await showLanguageSheet(context, current);
    final code = next == null ? null : appLanguageCodeFor(next);
    if (code == null) return;
    await ref
        .read(localeProvider.notifier)
        .setLocale(Locale(code), source: LanguageSource.pick);
  }

  /// Opens the help sheet and runs whatever came back.
  ///
  /// The sheet resolves a choice and nothing else -> every action runs from THIS context, with the
  /// sheet already gone: a confirm dialog raised under a closing sheet loses its route, and a toast
  /// belongs over Settings, not over something on its way out.
  Future<void> _needHelp() async {
    final action = await showHelpSheet(context);
    if (!mounted || action == null) return;
    switch (action) {
      case HelpAction.support:
        await _support();
      case HelpAction.manage:
        unawaited(context.push('/premium?source=settings'));
      case HelpAction.delete:
        await _delete();
    }
  }

  Future<void> _logout() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showArulConfirmDialog(
      context,
      title: l10n.settingsLogoutConfirmTitle,
      message: l10n.settingsLogoutConfirmBody,
      confirmLabel: l10n.settingsLogout,
    );
    // Unmounted = the session ended while the dialog was open and the wall already replaced
    // Settings -> nothing is left to sign out of, and `ref` is dead.
    if (ok != true || !mounted) return;
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
    // Same as [_logout]: a session that ended under the dialog leaves no account to delete here.
    if (ok != true || !mounted) return;
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

  static const double _pencilSlack = (ArulTokens.minHitTarget - 20) / 2;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    final l10n = AppLocalizations.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(
        ArulTokens.cardPadding16,
        ArulTokens.cardPadding16,
        ArulTokens.cardPadding16 - _pencilSlack,
        ArulTokens.cardPadding16,
      ),
      decoration: BoxDecoration(
        gradient: p.silk,
        border: Border.all(color: p.silkRim),
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
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  // Wraps before it clips: on a wide OEM font at 320 dp and 130% text, one line cut
                  // "Signed in with Google" short.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ArulTokens.rowSub.copyWith(
                    fontSize: 13,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // The pencil draws 20 inside a 48 box. The card's right padding gives up the 14 px of
          // slack (16 → 2), so the glyph's right edge stays on the same inner line as before and the
          // box is real hit area on both sides — a Transform would have painted the slack outside
          // its own bounds, where the hit test never reaches. The old 8 px gap is inside the slack.
          ArulIconTap(
            icon: Icons.edit,
            size: 20,
            color: p.accent,
            label: l10n.settingsEditNameTitle,
            identifier: 'arul_settings_edit_name',
            onTap: onEdit,
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
    required this.identifier,
    this.trailing,
  }) : assert(icon != null || glyph != null, 'a row needs one or the other');

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

  final String identifier;

  /// Replaces the chevron — a switch row toggles in place instead of opening anything.
  final Widget? trailing;
}

class _RowsCard extends StatelessWidget {
  const _RowsCard({required this.rows});

  final List<_RowData> rows;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);

    return Container(
      decoration: BoxDecoration(
        color: p.card,
        border: Border.all(color: p.borderQuiet),
        borderRadius: BorderRadius.circular(ArulTokens.rowsCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            _SettingsRow(data: rows[i]),
            if (i < rows.length - 1) Container(height: 1, color: p.divider),
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
    final p = ArulPalette.of(context);

    return Semantics(
      container: true,
      button: true,
      identifier: data.identifier,
      child: GestureDetector(
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
                  color: p.accentTint,
                  borderRadius: BorderRadius.circular(
                    ArulTokens.iconChipRadius,
                  ),
                ),
                child:
                    data.glyph?.call(p.accent) ??
                    Icon(
                      data.icon,
                      size: ArulTokens.iconChipIconSize,
                      color: p.accent,
                    ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: ArulTokens.rowTitle.copyWith(color: p.text),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      data.sub,
                      style: ArulTokens.rowSub.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              data.trailing ??
                  Icon(Icons.chevron_right, size: 20, color: p.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickBarSwitch extends StatelessWidget {
  const _QuickBarSwitch({required this.on, required this.onChanged});

  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);
    return Switch(
      value: on,
      onChanged: onChanged,
      // The row is the tap target -> the switch's own 48dp padding would make this row taller.
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      activeThumbColor: ArulTokens.thumbOn,
      activeTrackColor: p.accent,
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
    final p = ArulPalette.of(context);
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
            Text('·', style: ArulTokens.body.copyWith(color: p.textFaint)),
            _FooterLink(label: l10n.settingsTerms, doc: PolicyDoc.terms),
            Text('·', style: ArulTokens.body.copyWith(color: p.textFaint)),
            _FooterLink(label: l10n.settingsRefund, doc: PolicyDoc.refund),
          ],
        ),
        const SizedBox(height: 14),
        const _DmcaBadge(),
        if (info != null) ...[
          const SizedBox(height: 12),
          Text(
            'Version: ${info.version} (${info.buildNumber})',
            style: ArulTokens.caption.copyWith(color: p.textFaint),
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
    final p = ArulPalette.of(context);
    return Semantics(
      link: true,
      label: label,
      identifier: 'arul_policy_${doc.name}',
      onTap: () => context.push(doc.route),
      // The label is the visible link text -> without this it is announced twice.
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => ArulHaptics.tap(),
        // In-app, NEVER the browser — the policy is a pushed screen with its own back arrow.
        // A route, not an intent that can find no handler, so there is nothing to guard.
        onTap: () => context.push(doc.route),
        // A 20dp line of text is not a tap target. The label does not move — it centres in a
        // [ArulTokens.minHitTarget] box and the air around it becomes tappable, which is what
        // `opaque` above is for. The Wrap centres the separators against the taller run.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: ArulTokens.minHitTarget),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: ArulTokens.body.copyWith(
                fontWeight: FontWeight.w500,
                color: p.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DmcaBadge extends StatelessWidget {
  const _DmcaBadge();

  @override
  Widget build(BuildContext context) {
    final p = ArulPalette.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        border: Border.all(color: p.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 16, color: p.accent),
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
                    color: p.text,
                  ),
                ),
                TextSpan(
                  text: 'PROTECTED',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.7,
                    color: p.textSecondary,
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

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final p = ArulPalette.of(context);

    return ArulPressable(
      // Signing out is deliberate but not destructive — a firm press, one step below delete.
      haptic: ArulHapticStyle.firm,
      pressedScale: 0.97,
      onTap: onTap,
      builder: (context, pressed) => Container(
        height: ArulTokens.ctaHeight50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Held: the same maroon tint laid twice, so the press deepens the pill in both themes.
          color: pressed
              ? Color.alphaBlend(p.destructiveFill, p.destructiveFill)
              : p.destructiveFill,
          border: Border.all(color: p.destructiveRim),
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.logout, size: 20, color: p.destructiveInk),
            const SizedBox(width: 8),
            Text(
              l10n.settingsLogout,
              style: ArulTokens.button.copyWith(color: p.destructiveInk),
            ),
          ],
        ),
      ),
    );
  }
}
