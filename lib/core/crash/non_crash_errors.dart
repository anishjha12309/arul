import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';

/// Errors the app already survives, which Crashlytics must count as NON-fatal.
///
/// Every uncaught error reaches Crashlytics stamped FATAL, yet none of these ends the process.
/// A crash-free rate that counts network weather measures the users' signal, not the app.
///
/// Two classes qualify, and only these:
///   · Flutter's image pipeline ([library] is `image resource service`) — the framework catches it
///     and paints the errorBuilder; a broken image is a content or network fault, never a crash;
///   · transport failures on the app's own calls — offline, reset, TLS, timeout; the process lives;
///   · a dead refresh token ([ApiException.isSessionExpired]) — the tokens are already cleared and
///     the sign-in wall is the next screen, so it is a LOGOUT, not a crash. It was the app's single
///     largest "crash" (8 users in the 8 days to 10 Sep on builds 70+), i.e. a crash-free rate that
///     was measuring session lifetimes. Only the two terminal refresh codes qualify; a transient
///     refresh failure keeps its tokens and is not this.
///
/// Everything else stays FATAL on purpose — a bad cast or a disposed ref is a defect.
/// The fatal badge is what gets it looked at.
/// Non-fatals are still recorded and listed -> only the crash-free-users rate stops paying for them.
bool isNonCrashError(Object exception, {String? library}) {
  if (library == 'image resource service') return true;
  if (exception is ApiException) return exception.isSessionExpired;
  return exception is SocketException ||
      exception is HttpException ||
      exception is TlsException ||
      exception is TimeoutException ||
      exception is http.ClientException;
}
