import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'analytics_service.dart';

/// Real [AnalyticsService] backed by PostHog.
///
/// `Posthog().setup(...)` runs in `main()` -> this class only forwards onto that singleton.
/// Chosen over [NoOpAnalyticsService] only when a real project key is present
/// (`analytics_provider.dart`) -> tests and key-less dev builds stay offline.
/// The SDK queues and batch-uploads in the background -> fire-and-forget, never awaited on the UI path.
class PostHogAnalyticsService implements AnalyticsService {
  const PostHogAnalyticsService();

  /// Registered properties ride on the capture itself, under the event's own keys, not only through
  /// the SDK's `register`. `setup()` is fire-and-forget in `main()`, so on a FRESH install the
  /// sheet-first `login_attempt` lands after native setup (a capture before it is dropped) but
  /// before the Dart `register` round trip -> 80% of a build's cold-start attempts carried no
  /// `app_language` while the install event 20 ms later did. Merging here closes that window and
  /// costs one small map spread per event; the SDK's own register keeps the same value, never a
  /// different one.
  @override
  void track(String event, {Map<String, Object?>? properties}) {
    unawaited(
      Posthog().capture(
        eventName: event,
        properties: _clean(propertiesFor(properties)),
      ),
    );
  }

  /// The properties a capture sends: everything registered, overridden by the event's own.
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

  /// A PostHog super property. Held here as well as in the SDK for two windows the SDK cannot cover:
  /// `setup()` is fire-and-forget in `main()`, so the root listener's first call can arrive before
  /// native init (see [started]); and `reset()` "resets all cached properties", super properties
  /// included, so a sign-out would strip it from every event until the next change.
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

  /// Test seam: forget everything registered, as a fresh process would.
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
    for (final e in _registered.entries) {
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
