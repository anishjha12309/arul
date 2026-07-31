import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus;
import 'package:url_launcher/url_launcher.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/config/app_config.dart';
import '../providers/referral_providers.dart';
import 'install_referrer_service.dart';

/// The ONE outbound "tell a friend" path, shared by every surface that offers it
/// — Refer & Earn, the Settings row, and the post-purchase and post-upload
/// moments.
///
/// It exists because the copy and the attribution are the valuable parts, and
/// they were previously inlined in a single screen. Every new entry point that
/// re-derived them was a chance to ship a message in the wrong voice or a link
/// that credits nobody. There is now one place to get both right.
///
/// The payload here is TEXT ONLY, which is why WhatsApp is reached by deep link
/// rather than by the native targeted intent the wallpaper share needs — with no
/// file to carry, `whatsapp://send?text=` is the right tool and needs no
/// platform channel.
///
/// [source] names the surface and rides along on `referral_shared`, so the entry
/// points can be compared and the dead ones removed.
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
          // False means this share can never be credited back to the sender —
          // the summary hadn't loaded, or the account has no code yet. Worth
          // knowing per surface: a screen that always shares unattributed is a
          // screen whose warm-up is in the wrong place.
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

/// The referral-attributed Play link when the user's code is ALREADY known, the
/// plain listing otherwise.
///
/// Deliberately synchronous — it reads the cached summary and never awaits.
/// Sharing must not block on the network, and a share that pauses for a
/// round-trip is a share the user abandons.
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
