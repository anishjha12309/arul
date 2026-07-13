import 'dart:io';

import 'package:http/http.dart' as http;

/// True when [e] is a connectivity failure rather than a real bug.
///
/// The download and the catalog fetch both throw raw `ClientException` /
/// `SocketException` when the device is offline. The UI must say "you're
/// offline, retry" — never surface `ClientException: Failed host lookup`.
bool isNetworkError(Object e) =>
    e is SocketException ||
    e is http.ClientException ||
    e is HttpException ||
    e is HandshakeException;
