import 'dart:async';

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
/// path immediately before `supportsAuthenticate()`/`authenticate()`, so the
/// v7 contract (initialize → authenticate) still holds exactly as before. A
/// signed-out user pays the same total time; a signed-in user pays none of it.
///
/// [ready] NEVER throws. A failed init is swallowed here — same as the old
/// try/catch in `main()` — because `authenticate()` surfaces a localized
/// failure + retry on its own, and an unawaited future that throws would reach
/// the zone handler and be reported to Crashlytics as a FATAL.
abstract final class GoogleSignInInit {
  static Future<void>? _ready;

  /// Kicks off `initialize()` once. Safe to call more than once.
  static void start({required String serverClientId}) {
    _ready ??= GoogleSignIn.instance
        .initialize(serverClientId: serverClientId)
        .catchError((Object e) {
          debugPrint('[GoogleSignInInit] initialize failed: $e');
        });
  }

  /// Completes when `initialize()` has settled (successfully or not).
  /// Resolves immediately when [start] was never called (define-less runs and
  /// tests), which keeps the caller's own configuration guard authoritative.
  static Future<void> get ready => _ready ?? Future<void>.value();

  /// Test-only: forget the recorded call so each test starts clean.
  @visibleForTesting
  static void resetForTest() => _ready = null;
}
