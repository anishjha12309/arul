import '../../../data/models/app_config_model.dart';
import '../../../data/models/subscription_model.dart';
import 'cancel_offer.dart';
import 'entitlement.dart';

/// The Worker's own verdict on the ₹99 win-back: what the pay button and the push read.
bool winbackOffered(SubscriptionModel? sub) =>
    sub != null && sub.winbackOfferEligible && sub.trialEnd != null;

/// Whether a door no pay tap opened may offer ₹99: premium has run out and no setup is in flight.
/// Outside `/premium` the purchase notifier is gone, so `pending` is the only "mid-checkout" sign.
bool winbackReachable(Entitlement? entitlement) {
  if (entitlement == null || entitlement.isPremium) return false;
  final sub = entitlement.subscription;
  return winbackOffered(sub) && sub!.status != SubscriptionStatus.pending;
}

/// What opened the ₹99 win-back sheet when no pay tap did; rides on its events as `entry`.
enum WinbackEntry {
  push('push'),
  premiumTap('premium_tap'),
  daily('daily'),
  uninstallShortcut('uninstall_shortcut');

  const WinbackEntry(this.key);

  final String key;

  static const dailySource = 'daily';
  static const uninstallSource = 'uninstall_shortcut';

  /// Opened over the screen the person was on, so closing it returns them there.
  bool get sheetOnly => this == daily || this == uninstallShortcut;

  /// A premium tap keeps its gate's own `source`, so any other source with the offer is one.
  static WinbackEntry? fromRoute({required String source, String? offer}) {
    if (offer != kWinbackOffer) return null;
    return switch (source) {
      'push' => push,
      dailySource => daily,
      uninstallSource => uninstallShortcut,
      _ => premiumTap,
    };
  }
}

/// The CMS kill switches under `feature_flags.winback_reach`. Each is ON unless exactly `false`, and
/// an absent or still-loading config is ON: the doors ship live with the build (owner).
class WinbackReachFlags {
  const WinbackReachFlags({
    this.tapFirst = true,
    this.dailySheet = true,
    this.uninstallShortcut = true,
    this.countdown = true,
  });

  factory WinbackReachFlags.from(AppConfigModel? config) {
    final raw = config?.featureFlags['winback_reach'];
    bool on(String key) => !(raw is Map && raw[key] == false);
    return WinbackReachFlags(
      tapFirst: on('tap_first'),
      dailySheet: on('daily_sheet'),
      uninstallShortcut: on('uninstall_shortcut'),
      countdown: on('countdown'),
    );
  }

  final bool tapFirst;
  final bool dailySheet;
  final bool uninstallShortcut;

  /// The 10:00 hold on the doors no pay tap opened. Kept by the owner, a CCPA "false urgency" risk,
  /// so it can be withdrawn without a release.
  final bool countdown;
}

/// The paywall a blocked action opens; a lapsed returning user meets the ₹99 sheet on it first.
/// Only the CACHED `/me` decides: awaiting one here would hold every new user's trial paywall.
String premiumGateLocation(
  String source, {
  Entitlement? cached,
  AppConfigModel? config,
}) => Uri(
  path: '/premium',
  queryParameters: {
    'source': source,
    if (WinbackReachFlags.from(config).tapFirst && winbackReachable(cached))
      'offer': kWinbackOffer,
  },
).toString();

enum ShortcutLanding { hold, offer, appInfo }

/// Where an "Uninstall" tap goes. The label must stay true, so anything short of a ₹99 sheet that
/// can really open ends in App info: signed out, ineligible, switched off, or already on `/premium`.
ShortcutLanding decideShortcutLanding({
  required String path,
  required Entitlement? entitlement,
  required WinbackReachFlags flags,
}) {
  if (path == '/') return ShortcutLanding.hold;
  if (path == '/sign-in' || path == '/premium') return ShortcutLanding.appInfo;
  return flags.uninstallShortcut && winbackReachable(entitlement)
      ? ShortcutLanding.offer
      : ShortcutLanding.appInfo;
}
