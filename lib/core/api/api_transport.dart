import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The HTTP stack [ApiClient] runs on (docs/auth.md §Transport).
abstract final class ApiTransport {
  /// dart:io's default keeps an idle socket 15 s, shorter than the median wait on Google's sheet, so
  /// the login POST paid a fresh TLS handshake after the splash had already opened one.
  static http.Client socket() =>
      IOClient(HttpClient()..idleTimeout = const Duration(seconds: 120));
}
