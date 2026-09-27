import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/api_client.dart';

/// Errors the app already survives, which Crashlytics must count as NON-fatal.
/// Every uncaught error reaches Crashlytics stamped FATAL, yet none of these ends the process.
/// A crash-free rate that counts network weather measures the users' signal, not the app.
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
