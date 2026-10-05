import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

AppConfigModel _config(Map<String, dynamic> flags) => AppConfigModel(
  prices: const <String, dynamic>{},
  policyUrls: const <String, dynamic>{},
  featureFlags: flags,
);

Future<bool?> _flagFor(Future<AppConfigModel?> Function() build) async {
  final container = ProviderContainer(
    overrides: [appConfigProvider.overrideWithBuild((ref, _) => build())],
  );
  addTearDown(container.dispose);
  await container.read(appConfigProvider.future);
  return container.read(statusTabFlagProvider);
}

void main() {
  test(
    'a failed config fetch is unknown, not off — a cold status link keeps waiting',
    () async {
      expect(await _flagFor(() async => null), isNull);
    },
  );

  test('a loaded config without the flag is the two-tab app', () async {
    expect(await _flagFor(() async => _config(const {})), isFalse);
  });

  test('only a literal true turns the tab on', () async {
    expect(
      await _flagFor(() async => _config(const {'status_tab': true})),
      isTrue,
    );
    expect(
      await _flagFor(() async => _config(const {'status_tab': 'true'})),
      isFalse,
    );
  });
}
