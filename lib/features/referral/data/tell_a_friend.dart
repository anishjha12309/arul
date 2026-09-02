import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus;
import 'package:url_launcher/url_launcher.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../providers/referral_providers.dart';
import 'install_referrer_service.dart';

/// The ONE outbound "tell a friend" path, shared by every surface that offers it.
///
/// The copy and the attribution are the valuable parts, and every re-derivation risks both.
/// So there is one place to get the voice right and one place to get the credit right.
/// The payload here is TEXT ONLY -> WhatsApp by deep link, not the wallpaper share's file intent.
/// With no file to carry, `whatsapp://send?text=` needs no platform channel.
/// [source] names the surface and rides on `referral_shared` -> dead entry points are findable.
Future<void> tellAFriend(
  BuildContext context,
  WidgetRef ref, {
  required String source,
}) async {
  final l10n = AppLocalizations.of(context);
  final link = _referralLink(ref);
  final message = l10n.referShareMessage(link.url);

  ref
      .read(analyticsServiceProvider)
      .track(
        'referral_shared',
        properties: {
          'source': source,
          // False means this share can never be credited back — no summary yet, or no code.
          // Worth knowing per surface: always-unattributed means that screen's warm-up is misplaced.
          'link_attributed': link.attributed,
        },
      );

  final whatsapp = Uri.parse(
    'whatsapp://send?text=${Uri.encodeComponent(message)}',
  );
  try {
    if (await canLaunchUrl(whatsapp)) {
      final ok = await launchUrl(
        whatsapp,
        mode: LaunchMode.externalApplication,
      );
      if (ok) return;
    }
  } catch (_) {
    // WhatsApp missing / launch refused → the system sheet below.
  }
  await SharePlus.instance.share(ShareParams(text: message));
}

/// The referral-attributed Play link when the code is ALREADY known, the plain listing otherwise.
///
/// A share that pauses for a round trip is a share the user abandons.
/// So this is synchronous — it reads the cached summary and never awaits.
({String url, bool attributed}) _referralLink(WidgetRef ref) {
  final code = AppConfig.hasBackend
      ? ref.read(referralSummaryProvider).asData?.value.referralCode
      : null;
  if (code != null && code.isNotEmpty) {
    return (url: InstallReferrerService.buildShareLink(code), attributed: true);
  }
  return (
    url: 'https://play.google.com/store/apps/details?id=$kPlayPackageId',
    attributed: false,
  );
}
