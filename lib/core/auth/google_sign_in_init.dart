import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Owns the ONE `google_sign_in` v7 `initialize()` call and lets the sign-in
/// path await it without putting it on the cold-start critical path.
///
/// WHY THIS EXISTS: `initialize()` used to be `await`ed in `main()` BEFORE
/// `runApp()`, so every launch — including the already-signed-in ones that
/// never call `authenticate()` — paid Credential Manager / Play Services init
/// before the first frame. `google_sign_in`'s own documented example never
/// awaits it either; it wraps the call in `unawaited(...)` and chains off it
/// (pub.dev/packages/google_sign_in, "Initialization and authentication").
///
/// The wait is not removed, it is MOVED: [ready] is awaited in the sign-in
/// path immediately before `supportsAuthenticate()`, so the v7 contract
/// (initialize → sheet/button) still holds exactly as before. A signed-out
/// user pays the same total time; a signed-in user pays none of it.
///
/// [ready] NEVER throws. A failed init is swallowed here — same as the old
/// try/catch in `main()` — because the sign-in path surfaces a localized
/// failure + retry on its own, and an unawaited future that throws would reach
/// the zone handler and be reported to Crashlytics as a FATAL.
///
/// NONCE — a PER-PROCESS value, not per-request. The plugin accepts a nonce
/// only at `initialize()` and attaches that same one to every credential
/// request it makes afterwards (`GetGoogleIdOption` for the sheet AND
/// `GetSignInWithGoogleOption` for the button — google_sign_in_android
/// `GoogleSignInPlugin.java`), so what it buys is "only the process that
/// requested this token can redeem it", NOT "this token can be redeemed once".
/// The Worker checks the request nonce against the `nonce` claim in the ID
/// token (Google's SIWG guide: "ensure your server-side code validates that
/// the request and response nonces are identical"). Never log it, never track
/// it — it is a credential-binding secret for the life of the process.
abstract final class GoogleSignInInit {
  static Future<void>? _ready;
  static String? _nonce;

  /// Kicks off `initialize()` once. Safe to call more than once — a second
  /// call is a no-op and keeps the FIRST nonce, because that is the one the
  /// tokens Google has already minted for this process are bound to.
  static void start({required String serverClientId, String? nonce}) {
    if (_ready != null) return;
    _nonce = nonce;
    _ready = GoogleSignIn.instance
        .initialize(serverClientId: serverClientId, nonce: nonce)
        .catchError((Object e) {
          debugPrint('[GoogleSignInInit] initialize failed: $e');
        });
  }

  /// Completes when `initialize()` has settled (successfully or not).
  /// Resolves immediately when [start] was never called (define-less runs and
  /// tests), which keeps the caller's own configuration guard authoritative.
  static Future<void> get ready => _ready ?? Future<void>.value();

  /// The nonce every ID token minted in this process carries, or null when
  /// [start] ran without one (define-less runs and tests). Read-only: the
  /// exchange sends it so the Worker can match it against the token claim.
  static String? get nonce => _nonce;

  /// A cryptographically strong nonce, 32 random bytes in unpadded base64url —
  /// the shape of Google's own `generateSecureRandomNonce` sample
  /// (`Base64.NO_WRAP or URL_SAFE or NO_PADDING`). Called ONCE per process,
  /// from `main()`.
  static String generateNonce([int byteLength = 32]) {
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(byteLength, (_) => rng.nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Test-only: forget the recorded call so each test starts clean.
  @visibleForTesting
  static void resetForTest() {
    _ready = null;
    _nonce = null;
  }
}
