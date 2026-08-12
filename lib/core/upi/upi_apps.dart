import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'upi_apps.g.dart';

/// One installed, mandate-capable UPI app (from `UpiIntentChannel.kt`'s
/// allowlist — PhonePe's Autopay docs name which apps can approve a mandate,
/// so a generic upi:// resolver is deliberately never offered).
class UpiApp {
  const UpiApp({required this.packageName, required this.label, this.icon});

  final String packageName;
  final String label;

  /// App icon as PNG bytes, or null — the picker falls back to a glyph.
  final Uint8List? icon;
}

/// Platform bridge for the direct UPI-intent mandate flow.
class UpiApps {
  static const _channel = MethodChannel('com.hsrutility.arul/upi_intent');

  /// Installed mandate-capable UPI apps, in the channel's preference order.
  /// Best-effort: any failure returns an empty list, and the paywall then
  /// simply offers the hosted-page flow with no picker.
  static Future<List<UpiApp>> installed() async {
    try {
      final raw = await _channel.invokeListMethod<dynamic>('listUpiApps');
      if (raw == null) return const [];
      return [
        for (final entry in raw.whereType<Map<Object?, Object?>>())
          if (entry['package'] is String && entry['label'] is String)
            UpiApp(
              packageName: entry['package']! as String,
              label: entry['label']! as String,
              icon: entry['icon'] is Uint8List
                  ? entry['icon']! as Uint8List
                  : null,
            ),
      ];
    } catch (e) {
      debugPrint('[UpiApps] listUpiApps failed: $e');
      return const [];
    }
  }

  /// Fires [intentUrl] as an ACTION_VIEW aimed at [packageName]. False when
  /// the app can't take the intent — callers must abandon the claimed setup
  /// and surface a clean error, since nothing was authorized.
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

/// Installed mandate-capable UPI apps for the paywall picker. keepAlive: the
/// installed-apps set changes only when the user installs/uninstalls a UPI app
/// — re-querying PackageManager per paywall open buys nothing.
@Riverpod(keepAlive: true)
Future<List<UpiApp>> installedUpiApps(Ref ref) => UpiApps.installed();
