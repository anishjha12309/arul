import 'package:arul/core/analytics/analytics_provider.dart';
import 'package:arul/core/analytics/analytics_service.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/providers/locale_provider.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/data/repositories/repository_providers.dart';
import 'package:arul/features/quick_bar/data/quick_bar_channel.dart';
import 'package:arul/features/quick_bar/data/quick_bar_taps.dart';
import 'package:arul/features/quick_bar/providers/quick_bar_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBar extends QuickBarChannel {
  QuickBarStatus? current = const QuickBarStatus(
    permitted: true,
    channelBlocked: false,
  );
  final syncs = <({bool on, QuickBarLabels labels})>[];

  @override
  Future<QuickBarStatus?> sync({
    required bool on,
    required QuickBarLabels labels,
  }) async {
    syncs.add((on: on, labels: labels));
    return current;
  }

  @override
  Future<QuickBarStatus?> status() async => current;

  @override
  Future<void> openSettings() async {}

  String? parked;

  @override
  Future<String?> takePendingTab() async {
    final tab = parked;
    parked = null;
    return tab;
  }
}

class _RecordingAnalytics implements AnalyticsService {
  final events = <(String, Map<String, Object?>?)>[];

  @override
  void track(String event, {Map<String, Object?>? properties}) =>
      events.add((event, properties));

  @override
  void identify(String userId, {Map<String, Object?>? userProperties}) {}

  @override
  void screen(String name, {Map<String, Object?>? properties}) {}

  @override
  void reset() {}

  @override
  void register(String key, Object value) {}
}

class _English extends LocaleNotifier {
  @override
  Locale build() => const Locale('en');
}

AppConfigModel _config(Map<String, dynamic> flags) => AppConfigModel(
  prices: const <String, dynamic>{},
  policyUrls: const <String, dynamic>{},
  featureFlags: flags,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late _FakeBar bar;
  late _RecordingAnalytics analytics;

  Future<ProviderContainer> containerWith({
    Map<String, dynamic> flags = const {},
  }) async {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        quickBarChannelProvider.overrideWithValue(bar),
        analyticsServiceProvider.overrideWithValue(analytics),
        appConfigProvider.overrideWithBuild((ref, _) async => _config(flags)),
        localeProvider.overrideWith(_English.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appConfigProvider.future);
    return container;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    bar = _FakeBar();
    analytics = _RecordingAnalytics();
  });

  group('autoEnable', () {
    test('turns the bar on once notifications are allowed', () async {
      final container = await containerWith();
      await container.read(quickBarSettingProvider.notifier).autoEnable();

      expect(container.read(quickBarSettingProvider), isTrue);
      expect(prefs.getBool(QuickBarSetting.prefKey), isTrue);
      expect(analytics.events.single.$1, 'quick_bar_toggled');
      expect(analytics.events.single.$2, {'enabled': true, 'via': 'auto'});
    });

    test('a denial leaves the choice open for a later grant', () async {
      bar.current = const QuickBarStatus(
        permitted: false,
        channelBlocked: false,
      );
      final container = await containerWith();
      final setting = container.read(quickBarSettingProvider.notifier);

      await setting.autoEnable();
      expect(container.read(quickBarSettingProvider), isNull);
      expect(analytics.events, isEmpty);

      bar.current = const QuickBarStatus(
        permitted: true,
        channelBlocked: false,
      );
      await setting.autoEnable();
      expect(container.read(quickBarSettingProvider), isTrue);
    });

    test('a blocked bar channel is not a grant', () async {
      bar.current = const QuickBarStatus(permitted: true, channelBlocked: true);
      final container = await containerWith();
      await container.read(quickBarSettingProvider.notifier).autoEnable();

      expect(container.read(quickBarSettingProvider), isNull);
    });

    test('never overrides a choice the person made', () async {
      final container = await containerWith();
      final setting = container.read(quickBarSettingProvider.notifier);
      await setting.set(false, via: 'settings');
      await setting.autoEnable();

      expect(container.read(quickBarSettingProvider), isFalse);
      expect(analytics.events.single.$1, 'quick_bar_toggled');
      expect(analytics.events.single.$2, {'enabled': false, 'via': 'settings'});
    });

    test('two overlapping calls report one choice', () async {
      final container = await containerWith();
      final setting = container.read(quickBarSettingProvider.notifier);
      await Future.wait([setting.autoEnable(), setting.autoEnable()]);

      expect(container.read(quickBarSettingProvider), isTrue);
      expect(analytics.events, hasLength(1));
    });

    test('does nothing while the kill switch is on', () async {
      final container = await containerWith(flags: {'quick_bar': false});
      await container.read(quickBarSettingProvider.notifier).autoEnable();

      expect(container.read(quickBarSettingProvider), isNull);
    });
  });

  group('quickBarAllowed', () {
    test('a lifted kill switch brings the bar back', () async {
      (await containerWith(
        flags: {'quick_bar': false},
      )).read(quickBarKillSwitchProvider);
      final lifted = await containerWith();
      lifted.read(quickBarKillSwitchProvider);

      expect(lifted.read(quickBarAllowedProvider), isTrue);
      expect(prefs.getBool('arul_quick_bar_killed'), isFalse);
    });

    test('only a literal false kills it', () async {
      expect(
        (await containerWith(
          flags: {'quick_bar': 'false'},
        )).read(quickBarAllowedProvider),
        isTrue,
      );
      expect((await containerWith()).read(quickBarAllowedProvider), isTrue);
      expect(
        (await containerWith(
          flags: {'quick_bar': false},
        )).read(quickBarAllowedProvider),
        isFalse,
      );
    });

    test('a kill outlives a launch whose config never loads', () async {
      (await containerWith(
        flags: {'quick_bar': false},
      )).read(quickBarKillSwitchProvider);

      final offline = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appConfigProvider.overrideWithBuild((ref, _) async => null),
        ],
      );
      addTearDown(offline.dispose);
      await offline.read(appConfigProvider.future);

      expect(offline.read(quickBarAllowedProvider), isFalse);
    });
  });

  group('quickBarSync', () {
    test('mirrors the choice and English labels', () async {
      await prefs.setBool(QuickBarSetting.prefKey, true);
      final container = await containerWith();
      await container.read(quickBarSyncProvider.future);

      final sync = bar.syncs.single;
      expect(sync.on, isTrue);
      expect(sync.labels.wallpapers, 'Wallpaper');
      expect(sync.labels.ringtones, 'Ringtone');
      expect(sync.labels.channelName, 'Quick Access Bar');
    });

    test('the kill switch takes a chosen bar down', () async {
      await prefs.setBool(QuickBarSetting.prefKey, true);
      final container = await containerWith(flags: {'quick_bar': false});
      await container.read(quickBarSyncProvider.future);

      expect(bar.syncs.single.on, isFalse);
    });

    test('undecided is off', () async {
      final container = await containerWith();
      await container.read(quickBarSyncProvider.future);

      expect(bar.syncs.single.on, isFalse);
    });
  });

  group('QuickBarTaps', () {
    test('a parked tab opens once, stamped quick_bar', () async {
      final opened = <DeepLinkTarget>[];
      final taps = QuickBarTaps(channel: bar, onOpen: opened.add);
      addTearDown(taps.dispose);

      bar.parked = 'ringtones';
      await taps.take();
      await taps.take();

      expect(opened, [
        const TabLinkTarget(ArulTab.ringtones, source: DeepLinkSource.quickBar),
      ]);
    });

    test('an unknown or missing tab opens nothing', () async {
      final opened = <DeepLinkTarget>[];
      final taps = QuickBarTaps(channel: bar, onOpen: opened.add);
      addTearDown(taps.dispose);

      bar.parked = 'premium';
      await taps.take();
      await taps.take();

      expect(opened, isEmpty);
    });
  });
}
