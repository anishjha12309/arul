import 'package:flutter/services.dart';

/// What the native Play services check did for this phone.
enum PlayServicesFix {
  /// Play services can sign in -> nothing was shown, the failure was something else.
  available,

  /// Google's Update / Enable dialog is on screen. The way back in is the person's own return to
  /// the app, which the controller's return rule (or a cold start) already turns into a sign-in.
  shown,

  /// No dialog can fix this phone, or there is no native side to ask.
  unresolved,
}

/// Asks the native side to check Play services against what Credential Manager needs and, below
/// that, to show GOOGLE'S repair dialog.
///
/// The sign-in wall may not grow a sentence or a link, so a phone whose Play services cannot sign in
/// gets Google's dialog, never copy of ours. A healthy phone sees nothing: the native side answers
/// [PlayServicesFix.available] before any dialog call is made.
/// Never throws — every failure to ask reads as [PlayServicesFix.unresolved], which changes nothing.
class PlayServicesResolver {
  const PlayServicesResolver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.hsrutility.arul/play_services';

  final MethodChannel _channel;

  Future<PlayServicesFix> ensureAvailable() async {
    try {
      final answer = await _channel.invokeMethod<String>('ensureAvailable');
      return switch (answer) {
        'available' => PlayServicesFix.available,
        'shown' => PlayServicesFix.shown,
        _ => PlayServicesFix.unresolved,
      };
    } on Object {
      // PlatformException, MissingPluginException (no native side: tests, a future platform), or
      // no binding at all in a bare unit test -> all mean "could not ask", which changes nothing.
      return PlayServicesFix.unresolved;
    }
  }
}
