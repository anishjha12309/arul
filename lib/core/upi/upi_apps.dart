import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'upi_apps.g.dart';

/// One installed, mandate-capable UPI app, from `UpiIntentChannel.kt`'s allowlist.
/// PhonePe's docs name which apps can approve a mandate -> a generic upi:// resolver is never offered.
class UpiApp {
  const UpiApp({required this.packageName, required this.label, this.icon});

  final String packageName;
  final String label;

  /// App icon as PNG bytes, or null — the picker falls back to a glyph.
  final Uint8List? icon;
}

/// Short, stable analytics code for a UPI package — `other` for anything unknown.
///
/// The package name is 38 characters of noise in a breakdown, and GA4 does not parse numeric
/// parameter values into event-scoped custom dimensions on APP streams, so every analytics value
/// about UPI apps is one of these words. Keep in step with `MANDATE_APPS` in `UpiIntentChannel.kt`:
/// an app earning a place there without a code here reads as `other` and hides inside that bucket.
String upiAppCode(String packageName) => switch (packageName) {
  'com.phonepe.app' => 'phonepe',
  'com.google.android.apps.nbu.paisa.user' => 'gpay',
  'net.one97.paytm' => 'paytm',
  'in.org.npci.upiapp' => 'bhim',
  'com.phonepe.simulator' => 'ppesim',
  _ => 'other',
};

/// What the device probe found: the apps we offer, and the mandate handlers we refuse.
///
/// Two fields rather than one list because "this phone cannot pay" and "this phone has a UPI app we
/// do not offer" are different facts and only the first one justifies a dead CTA. 13% of everyone
/// who tapped Subscribe reached the SDK path -> that share is worth naming before it is designed for.
class UpiScan {
  const UpiScan({required this.apps, required this.otherPackages});

  const UpiScan.empty() : apps = const [], otherPackages = const [];

  /// Offered, in the channel's preference order.
  final List<UpiApp> apps;

  /// Packages that answer a mandate intent and are NOT on the allowlist, sorted.
  /// Reported to GA4 only; a package earns the picker with one real penny drop, never the resolver.
  final List<String> otherPackages;
}

/// Platform bridge for the direct UPI-intent mandate flow.
class UpiApps {
  static const _channel = MethodChannel('com.hsrutility.arul/upi_intent');

  /// The device probe: offered mandate-capable apps plus the mandate handlers the allowlist drops.
  /// Best-effort -> any failure returns an empty scan and the paywall shows the install prompt.
  static Future<UpiScan> scan() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'listUpiApps',
      );
      if (raw == null) return const UpiScan.empty();
      final offered = raw['offered'];
      final others = raw['others'];
      return UpiScan(
        apps: [
          if (offered is List)
            for (final entry in offered.whereType<Map<Object?, Object?>>())
              if (entry['package'] is String && entry['label'] is String)
                UpiApp(
                  packageName: entry['package']! as String,
                  label: entry['label']! as String,
                  icon: entry['icon'] is Uint8List
                      ? entry['icon']! as Uint8List
                      : null,
                ),
        ],
        otherPackages: others is List
            ? others.whereType<String>().toList(growable: false)
            : const [],
      );
    } catch (e) {
      debugPrint('[UpiApps] listUpiApps failed: $e');
      return const UpiScan.empty();
    }
  }

  /// [apps] with [remembered] floated to the head, everything below it in channel order.
  ///
  /// Pure, and here rather than in the screen so it can be pinned: one personal row, then the
  /// owner's order. Android exposes no permission-free "most used app" signal, so our own memory IS
  /// that signal. A remembered package that is no longer in [apps] — uninstalled, or dropped by the
  /// mandate probe — simply does not move anything.
  static List<UpiApp> ordered(List<UpiApp> apps, String? remembered) {
    if (remembered == null) return apps;
    final at = apps.indexWhere((a) => a.packageName == remembered);
    // -1 = gone since they picked it; 0 = already the head. Neither needs reordering.
    if (at <= 0) return apps;
    return [apps[at], ...apps.where((a) => a.packageName != remembered)];
  }

  /// Fires [intentUrl] as an ACTION_VIEW aimed at [packageName]; false when the app cannot take it.
  /// Nothing was authorized then -> the caller MUST abandon the claimed setup and show a clean error.
  static Future<bool> launch(String intentUrl, String packageName) async {
    try {
      final ok = await _channel.invokeMethod<bool>('launch', {
        'url': intentUrl,
        'package': packageName,
      });
      return ok == true;
    } catch (e) {
      debugPrint('[UpiApps] launch failed: $e');
      return false;
    }
  }
}

/// The device's UPI-mandate probe for the paywall picker.
/// The set changes only on an install or uninstall -> keepAlive; re-querying per open buys nothing.
@Riverpod(keepAlive: true)
Future<UpiScan> installedUpiApps(Ref ref) => UpiApps.scan();
