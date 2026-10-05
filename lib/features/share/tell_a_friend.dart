import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' show ShareParams, SharePlus;
import 'package:url_launcher/url_launcher.dart';

import '../../app/l10n/app_localizations.dart';
import '../../core/analytics/analytics_provider.dart';
import '../../core/deeplink/install_referrer_service.dart';
import '../wallpapers/data/direct_share_service.dart';

/// The ONE outbound "tell a friend" path, shared by every surface that offers it.
/// WhatsApp by a targeted text `ACTION_SEND`; `whatsapp://send?text=` is the fallback.
/// [source] names the surface and rides on `referral_shared` -> dead entry points are findable.
Future<void> tellAFriend(
  BuildContext context,
  WidgetRef ref, {
  required String source,
}) async {
  final l10n = AppLocalizations.of(context);
  final message = l10n.referShareMessage(_playListing);

  ref
      .read(analyticsServiceProvider)
      .track('referral_shared', properties: {'source': source});

  // Targeted ACTION_SEND first: it keeps WhatsApp's picker in Arul's task, so Back comes home.
  if (await ref.read(directShareServiceProvider).shareTextToWhatsApp(message)) {
    return;
  }
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

const _playListing =
    'https://play.google.com/store/apps/details?id=$kPlayPackageId';
