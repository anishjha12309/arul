import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Android's Data Saver on a metered link: background data blocked, the foreground asked to use less.
///
/// Budget users on prepaid packs run it, and a feed that stages clips ahead spends their data on
/// cards they may never reach. Read synchronously by the prefetcher, so the answer is cached and
/// re-asked in the background once it is [_maxAge] old; unknown reads as OFF (today's behaviour).
abstract final class DataSaver {
  static const _channel = MethodChannel('com.hsrutility.arul/build_info');
  static const _maxAge = Duration(seconds: 10);

  static bool _on = false;
  static DateTime? _askedAt;
  static Future<bool>? _inFlight;

  static bool get isOn {
    final at = _askedAt;
    if (at == null || DateTime.now().difference(at) > _maxAge) {
      unawaited(refresh());
    }
    return _on;
  }

  static Future<bool> refresh() => _inFlight ??= _ask().whenComplete(
    () => _inFlight = null,
  );

  static Future<bool> _ask() async {
    try {
      _on = await _channel.invokeMethod<bool>('dataSaverOn') ?? false;
    } catch (_) {
      // No channel (`flutter test`) or an OEM refusal -> keep the last answer.
    }
    _askedAt = DateTime.now();
    return _on;
  }

  @visibleForTesting
  static void debugSet(bool? on) {
    _on = on ?? false;
    _askedAt = on == null ? null : DateTime.now().add(const Duration(days: 1));
  }
}
