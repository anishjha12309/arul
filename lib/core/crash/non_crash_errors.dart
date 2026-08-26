import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Errors the app already survives, which Crashlytics must count as NON-fatal.
///
/// WHY: every uncaught error reaches Crashlytics through the handlers in
/// `main.dart`, stamped fatal — yet none of them ends the process. Flutter
/// reports the error and carries on. On 2026-08-26 the "crash" list was led by
/// CDN thumbnail loads dying on a flaky radio (`SocketException`, "Connection
/// closed while receiving data" — ~120 users in 30 days) and a 12 s refresh
/// timeout, while the one REAL crash on the list (a PhonePe SDK activity
/// result) sat at position nine. A crash-free rate that counts network weather
/// measures the users' signal, not the app.
///
/// Two classes qualify, and only these:
///   · anything from Flutter's image pipeline ([library] is
///     `image resource service`) — the framework catches the failure and
///     paints the errorBuilder; a broken image is a content or network fault,
///     never a crash;
///   · transport failures on the app's own calls — offline, reset, TLS,
///     timeout. The request layer retries or surfaces them; the process lives.
///
/// Everything else stays fatal on purpose: an unexpected Dart error — an
/// `ApiException` escaping an unawaited future, a bad cast, a disposed ref —
/// is a defect, and the fatal badge is what gets it looked at. Non-fatals are
/// still recorded and listed; only the crash-free-users rate stops paying for
/// them.
bool isNonCrashError(Object exception, {String? library}) {
  if (library == 'image resource service') return true;
  return exception is SocketException ||
      exception is HttpException ||
      exception is TlsException ||
      exception is TimeoutException ||
      exception is http.ClientException;
}
