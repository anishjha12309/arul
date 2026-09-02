import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Owns the ONE `google_sign_in` v7 `initialize()` call, awaitable off the cold-start critical path.
///
/// Awaiting it in `main()` made EVERY launch pay Credential Manager / Play Services init first.
/// That included already-signed-in launches, which never call `authenticate()` at all.
/// The plugin's own documented example does not await it either -> `unawaited(...)` and a chain.
/// The wait is MOVED, not removed: [ready] is awaited right before `supportsAuthenticate()`.
/// So the v7 contract (initialize → sheet/button) holds -> signed-out pays the same, signed-in none.
/// [ready] NEVER throws — an unawaited throw reaches the zone handler and reports a FATAL crash.
/// A failed init is swallowed here; the sign-in path surfaces its own localized failure and retry.
/// NONCE — a PER-PROCESS value, never per-request: the plugin accepts one only at `initialize()`.
/// It attaches that one to every later credential request, the sheet's and the button's alike.
/// So it buys "only this process can redeem the token", NOT "the token can be redeemed once".
/// The Worker matches the request nonce against the `nonce` claim in the ID token.
/// Never log it and never track it — a credential-binding secret for the life of the process.
abstract final class GoogleSignInInit {
  static Future<void>? _ready;
  static String? _nonce;

  /// Kicks off `initialize()` once; a second call is a no-op.
  /// It keeps the FIRST nonce -> that is what the tokens already minted for this process are bound to.
  static void start({required String serverClientId, String? nonce}) {
    if (_ready != null) return;
    _nonce = nonce;
    _ready = GoogleSignIn.instance
        .initialize(serverClientId: serverClientId, nonce: nonce)
        .catchError((Object e) {
          debugPrint('[GoogleSignInInit] initialize failed: $e');
        });
  }

  /// Completes when `initialize()` has settled, successfully or not.
  /// [start] never called (define-less runs, tests) -> resolves at once, the caller's guard decides.
  static Future<void> get ready => _ready ?? Future<void>.value();

  /// The nonce every ID token minted in this process carries; null when [start] ran without one.
  /// Read-only — the exchange sends it so the Worker can match it against the token claim.
  static String? get nonce => _nonce;

  /// A strong nonce — 32 random bytes, unpadded base64url, the shape of Google's own sample.
  /// Called ONCE per process, from `main()`.
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
