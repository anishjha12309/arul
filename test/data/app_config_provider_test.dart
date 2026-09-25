// appConfigProvider must not keep a failed cold-start fetch for the whole process: an offline start
// would otherwise hold the built-in chip order, default prices and no feature flags until the next
// cold start. It refetches on the offline->online edge and on a short ladder.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/connectivity/connectivity_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/settings/domain/app_config_repository.dart';

class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this._initial, this._changes);

  final List<ConnectivityResult> _initial;
  final Stream<List<ConnectivityResult>> _changes;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => _initial;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo implements AppConfigRepository {
  AppConfigModel? answer;
  var calls = 0;

  @override
  Future<AppConfigModel?> getAppConfig() async {
    calls++;
    return answer;
  }
}

const _config = AppConfigModel(
  prices: {
    'monthly': {'amount': 19900},
  },
  policyUrls: <String, dynamic>{},
  featureFlags: <String, dynamic>{'return_video': true},
);

void main() {
  late StreamController<List<ConnectivityResult>> changes;
  late _Repo repo;
  late ProviderContainer container;

  void setUpContainer(List<ConnectivityResult> initial) {
    changes = StreamController<List<ConnectivityResult>>.broadcast();
    repo = _Repo();
    container = ProviderContainer(
      overrides: [
        connectivityProvider.overrideWithValue(
          _FakeConnectivity(initial, changes.stream),
        ),
        appConfigRepositoryProvider.overrideWithValue(repo),
      ],
    );
  }

  test('an offline cold start refetches on the offline->online edge', () {
    fakeAsync((async) {
      setUpContainer([ConnectivityResult.none]);
      final sub = container.listen(appConfigProvider, (_, _) {});
      async.flushMicrotasks();
      expect(container.read(appConfigProvider).value, isNull);
      expect(repo.calls, 1);

      repo.answer = _config;
      changes.add([ConnectivityResult.mobile]);
      async.flushMicrotasks();

      expect(container.read(appConfigProvider).value, _config);
      expect(repo.calls, 2, reason: 'the edge refetched, not the ladder');

      async.elapse(const Duration(minutes: 5));
      expect(repo.calls, 2, reason: 'a success stops the ladder');
      sub.close();
      container.dispose();
      unawaited(changes.close());
    });
  });

  test('a slow "online" link retries on the ladder, then stops', () {
    fakeAsync((async) {
      setUpContainer([ConnectivityResult.mobile]);
      final sub = container.listen(appConfigProvider, (_, _) {});
      async.flushMicrotasks();
      expect(repo.calls, 1);

      for (final step in AppConfigNotifier.retryLadder) {
        async.elapse(step);
      }
      expect(repo.calls, 1 + AppConfigNotifier.retryLadder.length);
      expect(container.read(appConfigProvider).value, isNull);

      async.elapse(const Duration(minutes: 10));
      expect(
        repo.calls,
        1 + AppConfigNotifier.retryLadder.length,
        reason: 'one ladder, never a poll',
      );
      sub.close();
      container.dispose();
      unawaited(changes.close());
    });
  });

  test('a refetch never passes through loading', () {
    fakeAsync((async) {
      setUpContainer([ConnectivityResult.none]);
      final seen = <AsyncValue<AppConfigModel?>>[];
      final sub = container.listen(
        appConfigProvider,
        (_, next) => seen.add(next),
      );
      async.flushMicrotasks();
      seen.clear();

      repo.answer = _config;
      changes.add([ConnectivityResult.wifi]);
      async.flushMicrotasks();

      expect(seen.whereType<AsyncLoading<AppConfigModel?>>(), isEmpty);
      expect(seen.last.value, _config);
      sub.close();
      container.dispose();
      unawaited(changes.close());
    });
  });
}
