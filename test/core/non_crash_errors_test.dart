// Tests for isNonCrashError — the classifier that keeps Crashlytics'
// crash-free rate about crashes. Image-pipeline and transport failures are
// demoted to non-fatal; every other error stays fatal.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

  test('everything else stays fatal', () {
    expect(isNonCrashError(StateError('ref disposed')), isFalse);
    expect(
      isNonCrashError(StateError('overflow'), library: 'rendering library'),
      isFalse,
    );
    expect(isNonCrashError(ArgumentError('x')), isFalse);
  });
}
