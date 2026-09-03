import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// The only two places a failed sign-in may send the user.
///
/// Both are OUTSIDE the app, and both are best-effort: a link that cannot resolve must fail
/// silently, never toast. The nudge above it already told the user what happened, and a second
/// error about the help link teaches nothing.
///
/// An interface, not free functions, so a widget test can prove a tap opened the RIGHT target —
/// and, more importantly, that it never started or cancelled a sign-in attempt.
abstract interface class SignInHelpLinks {
  /// The phone's Google account screen, for an account Google refuses to re-verify.
  Future<void> openAccountSettings();

  /// The Play listing for Google Play services, for a provider that is missing or broken.
  Future<void> openPlayServices();
}

class PlatformSignInHelpLinks implements SignInHelpLinks {
  const PlatformSignInHelpLinks();

  /// `url_launcher` builds an `ACTION_VIEW` from a URI and nothing else — it has no
  /// `Intent.parseUri`, so an `intent:` URL resolves to nothing and a settings ACTION is out of
  /// its reach. Hence the channel, which walks the same candidate chain as the ringtone screen's
  /// WRITE_SETTINGS deep link (MainActivity).
  static const _channel = MethodChannel('com.hsrutility.arul/sign_in_help');

  /// Deep-links the Play app when it is installed; the https form opens the Play app OR a browser,
  /// so it is the fallback rather than a second failure.
  static final _playServicesMarket = Uri.parse(
    'market://details?id=com.google.android.gms',
  );
  static final _playServicesWeb = Uri.parse(
    'https://play.google.com/store/apps/details?id=com.google.android.gms',
  );

  @override
  Future<void> openAccountSettings() async {
    try {
      await _channel.invokeMethod<void>('openAccountSettings');
    } catch (e) {
      debugPrint('[SignInHelpLinks] account settings unreachable: $e');
    }
  }

  @override
  Future<void> openPlayServices() async {
    // No `canLaunchUrl` on `market://` — that asks the package manager, which Android 11 package
    // visibility answers "no" for without a `<queries>` entry the app does not need to ship.
    // Launching and catching is the same question, asked where the answer is honest.
    for (final uri in [_playServicesMarket, _playServicesWeb]) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } catch (e) {
        debugPrint('[SignInHelpLinks] $uri refused: $e');
      }
    }
  }
}
