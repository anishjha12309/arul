import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sends a wallpaper file straight to one app, skipping the system chooser.
///
/// WhatsApp is where these wallpapers travel, and every chooser tap is a share that does not happen.
/// A wallpaper share's payload is the MEDIA, and `whatsapp://send?text=` carries text only.
/// It would silently drop the file and send a naked caption -> a native targeted `ACTION_SEND`.
/// [shareToWhatsApp] returning false is ROUTINE — no WhatsApp, or a refused mime type.
/// So EVERY caller must fall back to the system sheet.
class DirectShareService {
  const DirectShareService([this._channel = _defaultChannel]);

  static const _defaultChannel = MethodChannel(
    'com.hsrutility.arul/direct_share',
  );

  final MethodChannel _channel;

  /// Consumer WhatsApp first, then WhatsApp Business.
  /// Both are in the manifest's `<queries>` — without it Android 11+ hides them from every resolve.
  static const _whatsAppPackages = ['com.whatsapp', 'com.whatsapp.w4b'];

  /// Hands [filePath] and [text] to WhatsApp; returns whether it opened.
  ///
  /// NEVER throws — a share degrades to the system sheet, never to an error toast one tap from done.
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
        // bad_input, or no channel at all — try the next package, then give up to the sheet.
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
