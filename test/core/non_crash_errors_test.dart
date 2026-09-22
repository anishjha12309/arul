// isNonCrashError keeps Crashlytics' crash-free rate about CRASHES -> image-pipeline and transport failures demote.
// Every other error stays fatal -> a wrong demotion hides a real crash.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:arul/core/api/api_client.dart';
import 'package:arul/core/crash/non_crash_errors.dart';

void main() {
  test('image pipeline and transport failures are non-crash', () {
    expect(
      isNonCrashError(StateError('decode'), library: 'image resource service'),
      isTrue,
    );
    expect(
      isNonCrashError(const SocketException('Connection reset by peer')),
      isTrue,
    );
    expect(
      isNonCrashError(
        http.ClientException('Connection closed while receiving data'),
      ),
      isTrue,
    );
    expect(isNonCrashError(TimeoutException('12s')), isTrue);
    expect(isNonCrashError(const HandshakeException('tls')), isTrue);
    expect(isNonCrashError(const HttpException('bad')), isTrue);
  });

  // A retired refresh token signs the user out and shows the wall. Counting that as a crash made it
  // the biggest entry in Crashlytics; a TRANSIENT refresh failure keeps its tokens and stays fatal.
  test('a dead refresh token is a sign-out, not a crash', () {
    expect(
      isNonCrashError(
        const ApiException(
          code: 'invalid_refresh',
          message: 'Session expired — please sign in again.',
          status: 401,
        ),
      ),
      isTrue,
    );
    expect(
      isNonCrashError(
        const ApiException(
          code: 'invalid_refresh_response',
          message: 'Unexpected refresh response.',
          status: 500,
        ),
      ),
      isTrue,
    );
    expect(
      isNonCrashError(
        const ApiException(
          code: 'refresh_unavailable',
          message: 'Could not reach the server. Please try again.',
          status: 503,
        ),
      ),
      isFalse,
    );
    expect(
      isNonCrashError(
        const ApiException(
          code: 'server_error',
          message: 'Internal server error',
          status: 500,
        ),
      ),
      isFalse,
    );
  });

  test('everything else stays fatal', () {
    expect(isNonCrashError(StateError('ref disposed')), isFalse);
    expect(
      isNonCrashError(StateError('overflow'), library: 'rendering library'),
      isFalse,
    );
    expect(isNonCrashError(ArgumentError('x')), isFalse);
  });
}
