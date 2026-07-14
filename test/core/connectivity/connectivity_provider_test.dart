// Tests for the offline gate's connectivity layer: isOnlineProvider maps the
// connectivity_plus snapshot/stream to a plain online/offline bool. A fake
// Connectivity is injected via connectivityProvider (the real plugin has no
// platform channel under `flutter test`).
//
// Values are captured via `container.listen` (how a widget consumes the
// provider) rather than `.future`: the seed stream closes right after its first
// value, and reading `.future` on a just-closed StreamProvider with no active
// listener never settles. Production reads it with `ref.watch`, which is the
// listen path exercised here.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/connectivity/connectivity_provider.dart';

/// Minimal fake: a seeded [checkConnectivity] result plus an optional change
/// stream. `noSuchMethod` covers any interface members the provider doesn't use.
class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this._initial, [Stream<List<ConnectivityResult>>? changes])
    : _changes = changes ?? const Stream.empty();

  final List<ConnectivityResult> _initial;
  final Stream<List<ConnectivityResult>> _changes;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => _initial;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  ProviderContainer containerFor(Connectivity c) {
    final container = ProviderContainer(
      overrides: [connectivityProvider.overrideWithValue(c)],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The first online/offline value the provider emits for [c].
  Future<bool> firstOnline(Connectivity c) {
    final container = containerFor(c);
    final done = Completer<bool>();
    container.listen(isOnlineProvider, (_, next) {
      if (!done.isCompleted && next is AsyncData<bool>) {
        done.complete(next.value);
      }
    }, fireImmediately: true);
    return done.future.timeout(const Duration(seconds: 5));
  }

  group('seed from checkConnectivity', () {
    test('[none] seeds offline (false)', () async {
      expect(
        await firstOnline(_FakeConnectivity(const [ConnectivityResult.none])),
        isFalse,
      );
    });

    test('empty result seeds offline (false)', () async {
      expect(await firstOnline(_FakeConnectivity(const [])), isFalse);
    });

    for (final r in const [
      ConnectivityResult.wifi,
      ConnectivityResult.mobile,
      ConnectivityResult.ethernet,
      ConnectivityResult.vpn,
    ]) {
      test('[$r] seeds online (true)', () async {
        expect(await firstOnline(_FakeConnectivity([r])), isTrue);
      });
    }

    test(
      'a failing probe is treated as online (never bounces a live feed)',
      () async {
        expect(await firstOnline(_ThrowingCheck()), isTrue);
      },
    );
  });

  test('follows onConnectivityChanged: online → offline → online', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    addTearDown(changes.close);
    final container = containerFor(
      _FakeConnectivity(const [ConnectivityResult.wifi], changes.stream),
    );

    final seen = <bool>[];
    container.listen(isOnlineProvider, (_, next) {
      if (next is AsyncData<bool>) seen.add(next.value);
    }, fireImmediately: true);

    // Let the seed resolve.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    changes.add(const [ConnectivityResult.none]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    changes.add(const [ConnectivityResult.wifi]);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(seen, [true, false, true]);
  });
}

/// A Connectivity whose initial probe throws — for the fail-open seed case.
class _ThrowingCheck implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      throw Exception('no platform');

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
