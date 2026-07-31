import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sends a wallpaper file straight to one app, skipping the system chooser.
///
/// WhatsApp is where these wallpapers actually travel, and every tap the chooser
/// adds is a share that does not happen. But a wallpaper share's payload is the
/// MEDIA, and the `whatsapp://send?text=` deep link the referral screen uses
/// carries text only — it would silently drop the file and send a naked caption.
/// So this goes through a native targeted `ACTION_SEND` instead (see
/// `DirectShareChannel.kt`), which keeps the file.
///
/// [shareToWhatsApp] returning false is ROUTINE — no WhatsApp installed, or it
/// refused the mime type — and every caller must fall back to the system sheet.
class DirectShareService {
  const DirectShareService([this._channel = _defaultChannel]);

  static const _defaultChannel = MethodChannel('com.hsrapps.arul/direct_share');

  final MethodChannel _channel;

  /// Consumer WhatsApp first, then WhatsApp Business. Both are declared in the
  /// manifest's `<queries>`, without which Android 11+ package visibility hides
  /// them and every resolve returns nothing.
  static const _whatsAppPackages = ['com.whatsapp', 'com.whatsapp.w4b'];

  /// Hands [filePath] + [text] to WhatsApp. Returns whether it opened.
  ///
  /// Never throws: a share must degrade to the system sheet, never to an error
  /// toast on a user who was one tap from sending a wallpaper to their family.
  Future<bool> shareToWhatsApp({
    required String filePath,
    required String mimeType,
    required String text,
  }) async {
    for (final package in _whatsAppPackages) {
      try {
        final ok = await _channel.invokeMethod<bool>('shareToPackage', {
          'package': package,
          'filePath': filePath,
          'mimeType': mimeType,
          'text': text,
        });
        if (ok ?? false) return true;
      } on PlatformException {
        // bad_input, or a channel that isn't there (tests) — try the next
        // package, then give up to the sheet.
      } on MissingPluginException {
        return false;
      }
    }
    return false;
  }
}

/// Overridable seam — there is no platform channel in pure-Dart tests.
final directShareServiceProvider = Provider<DirectShareService>(
  (ref) => const DirectShareService(),
);
