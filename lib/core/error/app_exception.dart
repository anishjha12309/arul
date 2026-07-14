import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

sealed class AppException implements Exception {
  const AppException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class NetworkException extends AppException {
  const NetworkException([
    super.message = 'Network error. Check your connection.',
  ]);
}

final class AuthException extends AppException {
  const AuthException([super.message = 'Authentication failed.']);
}

final class PremiumRequiredException extends AppException {
  const PremiumRequiredException() : super('Premium subscription required.');
}

final class StorageException extends AppException {
  const StorageException([super.message = 'Storage operation failed.']);
}

final class ServerException extends AppException {
  const ServerException([super.message = 'Server error. Please try again.']);
}

final class ValidationException extends AppException {
  const ValidationException(super.message);
}

final class NotFoundException extends AppException {
  const NotFoundException([super.message = 'Resource not found.']);
}

/// True when [error] is a connectivity-class failure (offline / unreachable
/// host / timed-out socket) rather than a server response. Used to decide
/// whether to surface a "check your internet" message + retry. A non-2xx HTTP
/// *response* is NOT a network error — it means we reached the server.
bool isNetworkError(Object error) =>
    error is NetworkException ||
    error is SocketException ||
    error is TimeoutException ||
    error is HttpException ||
    error is http.ClientException;

/// Maps raw exceptions to typed [AppException]s at the data layer boundary.
AppException mapException(Object error) {
  if (error is AppException) return error;
  final msg = error.toString();
  if (msg.contains('network') ||
      msg.contains('socket') ||
      msg.contains('connection')) {
    return NetworkException(msg);
  }
  if (msg.contains('auth') || msg.contains('unauthorized')) {
    return AuthException(msg);
  }
  return ServerException(msg);
}
