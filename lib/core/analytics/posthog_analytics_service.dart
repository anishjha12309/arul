import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'analytics_service.dart';

/// Real [AnalyticsService] backed by PostHog.
/// `Posthog().setup(...)` runs in `main()` -> this class only forwards onto that singleton.
class PostHogAnalyticsService implements AnalyticsService {
  const PostHogAnalyticsService();

  @override
  void track(String event, {Map<String, Object?>? properties}) {
    unawaited(
      Posthog().capture(
        eventName: event,
        properties: _clean(propertiesFor(properties)),
      ),
    );
  }

  @visibleForTesting
  static Map<String, Object?> propertiesFor(Map<String, Object?>? properties) =>
      {..._registered, ...?properties};

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {
    unawaited(
      Posthog().identify(
        userId: userId,
        userProperties: _clean(userProperties),
      ),
    );
  }

  @override
  void screen(String name, {Map<String, Object?>? properties}) {
    unawaited(
      Posthog().screen(screenName: name, properties: _clean(properties)),
    );
  }

  @override
  void reset() => unawaited(_resetKeepingRegistered());

  @override
  void register(String key, Object value) {
    _registered[key] = value;
    if (_started) unawaited(Posthog().register(key, value));
  }

  static final _registered = <String, Object>{};
  static var _started = false;

  /// Called by `main()` BEFORE `setup()` starts, synchronously: [initial] is the launch value for
  /// a key the app has not registered yet, and it must be in place before any widget can track —
  /// the first frame's `login_attempt` and `Application Installed` both fire ahead of the root
  /// listener that would register it. A key the app registered first keeps its value.
  static void prime(Map<String, Object> initial) {
    for (final e in initial.entries) {
      _registered.putIfAbsent(e.key, () => e.value);
    }
  }

  /// Called by `main()` once `setup()` has completed: pushes everything registered so far into the
  /// SDK, so later captures carry it whether or not they pass through [track].
  static Future<void> started() async {
    _started = true;
    await _applyRegistered();
  }

  @visibleForTesting
  static void resetForTest() {
    _registered.clear();
    _started = false;
  }

  static Future<void> _resetKeepingRegistered() async {
    await Posthog().reset();
    await _applyRegistered();
  }

  static Future<void> _applyRegistered() async {
    // A copy: [register] adds keys while these awaits run, and a map changed mid-loop throws — that
    // killed startup before `Application Installed` on most fresh installs. [register] sends those itself.
    for (final e in [..._registered.entries]) {
      await Posthog().register(e.key, e.value);
    }
  }

  /// The SDK takes `Map<String, Object>` but our interface allows nulls -> drop null entries.
  /// An empty or absent map -> `null`, never `{}`.
  Map<String, Object>? _clean(Map<String, Object?>? props) {
    if (props == null) return null;
    final out = <String, Object>{};
    props.forEach((key, value) {
      if (value != null) out[key] = value;
    });
    return out.isEmpty ? null : out;
  }
}
