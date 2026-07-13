import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import 'settings_sections.dart';

final _versionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Gap.xxl),
        children: [
          SettingsSection(title: l10n.settingsAppearance),
          const ThemeModePicker(),

          SettingsSection(title: l10n.settingsContent),
          // Sign-in is HERE and nowhere else. Browsing and previewing are free, so
          // demanding an account before the app will show a single wallpaper is a
          // good way to be uninstalled. Identity is asked for when something
          // actually needs it — entitlement, uploads, a collection that survives a
          // new phone — and this is the door to it.
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(l10n.signInGoogle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/sign-in'),
          ),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: Text(l10n.uploadTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/upload'),
          ),
          ListTile(
            leading: const Icon(Icons.workspace_premium_outlined),
            title: Text(l10n.premiumTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/premium?source=settings'),
          ),

          SettingsSection(title: l10n.settingsAbout),
          ListTile(
            leading: const Icon(Icons.mail_outline_rounded),
            title: Text(l10n.settingsSupport),
            subtitle: Text(AppConfig.supportEmail),
            onTap: () => _open(
              context,
              Uri(
                scheme: 'mailto',
                path: AppConfig.supportEmail,
                queryParameters: {'subject': 'Arul - Support Request'},
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.settingsPrivacy),
            onTap: () => _open(context, Uri.parse(AppConfig.privacyUrl)),
          ),
          ref
              .watch(_versionProvider)
              .maybeWhen(
                data: (v) => ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: Text(l10n.settingsVersion),
                  subtitle: Text(v),
                ),
                orElse: () => const SizedBox.shrink(),
              ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    // launchUrl THROWS (PlatformException), it does not merely return false, when
    // no app can handle the intent — which is the normal state of a device with no
    // mail client for our `mailto:` support link. Uncaught, that killed the toast
    // and the user got nothing at all when tapping "Need help".
    bool ok;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      showArulToast(
        context,
        AppLocalizations.of(context).errorGeneric,
        kind: ToastKind.error,
      );
    }
  }
}
