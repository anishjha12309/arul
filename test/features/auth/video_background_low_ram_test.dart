import 'package:arul/core/config/build_info.dart';
import 'package:arul/features/auth/presentation/widgets/video_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the low-memory contract of the auth background: on a phone the native probe calls
/// low-memory, NO native player is created — the still poster is the whole background.
/// On every other phone the shared player is created as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const buildInfo = MethodChannel('com.hsrutility.arul/build_info');
  const feedVideo = MethodChannel('com.hsrutility.arul/feed_video');
  const feedVideoEvents = MethodChannel(
    'com.hsrutility.arul/feed_video_events',
  );

  late List<String> videoCalls;

  void mockLowRam(bool isLow) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The poster rule is now the `low` rung of the device tier -> the probe the widget makes is
    // `deviceTier`, and `DeviceMemory.isLow` derives from its answer.
    messenger.setMockMethodCallHandler(buildInfo, (call) async {
      if (call.method == 'deviceTier') {
        return <String, Object?>{'tier': isLow ? 'low' : 'high'};
      }
      return null;
    });
    // The event channel's listen/cancel must not throw -> a no-op handler.
    messenger.setMockMethodCallHandler(feedVideoEvents, (_) async => null);
    // Returning null from `create` is the "platform unavailable" answer -> the holder tears down
    // at once with no grace timer, so the test ends with nothing pending.
    messenger.setMockMethodCallHandler(feedVideo, (call) async {
      videoCalls.add(call.method);
      return null;
    });
  }

  setUp(() {
    videoCalls = <String>[];
    DeviceQuality.resetForTesting();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(buildInfo, null);
    messenger.setMockMethodCallHandler(feedVideo, null);
    messenger.setMockMethodCallHandler(feedVideoEvents, null);
    DeviceQuality.resetForTesting();
  });

  Future<void> mountAndUnmount(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VideoBackground())),
    );
    // The probe and the acquire are both async -> two frames let them settle.
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    // Unmount so the holder releases; one more frame lets the async release run.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('low-memory phone: poster only, no native player is created', (
    tester,
  ) async {
    mockLowRam(true);
    await mountAndUnmount(tester);
    expect(videoCalls, isNot(contains('create')));
  });

  testWidgets('ordinary phone: the shared player is created', (tester) async {
    mockLowRam(false);
    await mountAndUnmount(tester);
    expect(videoCalls, contains('create'));
  });

  test('DeviceMemory fails open to false when no channel answers', () async {
    // No mock handler at all -> MissingPluginException -> the tier fails open to `mid`, which is
    // not `low`, so the phone is treated as ordinary and keeps its video.
    expect(await DeviceMemory.isLow, isFalse);
    expect(DeviceQuality.resolved, DeviceTier.mid);
  });

  test('an unreadable tier name fails open to mid, never to low', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(buildInfo, (call) async {
      if (call.method == 'deviceTier') {
        return <String, Object?>{'tier': 'gibberish'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(buildInfo, null));
    expect(await DeviceQuality.tier, DeviceTier.mid);
    expect(await DeviceMemory.isLow, isFalse);
  });

  test('a low tier is what DeviceMemory.isLow reports', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(buildInfo, (call) async {
      if (call.method == 'deviceTier') {
        return <String, Object?>{'tier': 'low', 'totalMem': 2800000000};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(buildInfo, null));
    expect(await DeviceMemory.isLow, isTrue);
    expect(DeviceMemory.resolved, isTrue);
    expect(DeviceQuality.facts['totalMem'], 2800000000);
  });
}
