// Tests for the typed AppException hierarchy and mapException(), the data-layer
// boundary that converts raw errors into typed exceptions.

import 'package:flutter_test/flutter_test.dart';
import 'package:arul/core/error/app_exception.dart';

void main() {
  group('AppException defaults', () {
    test('each variant carries a default message and is an AppException', () {
      expect(const NetworkException(), isA<AppException>());
      expect(const NetworkException().message, isNotEmpty);
      expect(const AuthException().message, isNotEmpty);
      expect(
        const PremiumRequiredException().message,
        'Premium subscription required.',
      );
      expect(const StorageException().message, isNotEmpty);
      expect(const ServerException().message, isNotEmpty);
      expect(const NotFoundException().message, isNotEmpty);
    });

    test('ValidationException requires an explicit message', () {
      expect(const ValidationException('bad input').message, 'bad input');
    });

    test('toString includes the concrete runtime type', () {
      expect(
        const NotFoundException().toString(),
        contains('NotFoundException'),
      );
    });
  });

  group('mapException', () {
    test('passes an existing AppException through unchanged', () {
      const original = PremiumRequiredException();
      expect(identical(mapException(original), original), isTrue);
    });

    test('maps network/socket/connection text to NetworkException', () {
      expect(mapException(Exception('socket failed')), isA<NetworkException>());
      expect(
        mapException(Exception('connection reset')),
        isA<NetworkException>(),
      );
      expect(mapException(Exception('network down')), isA<NetworkException>());
    });

    test('maps auth/unauthorized text to AuthException', () {
      expect(mapException(Exception('unauthorized')), isA<AuthException>());
      expect(mapException(Exception('auth token bad')), isA<AuthException>());
    });

    test('falls back to ServerException for anything else', () {
      expect(mapException(Exception('teapot')), isA<ServerException>());
    });
  });
}
