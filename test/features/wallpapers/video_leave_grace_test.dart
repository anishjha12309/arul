// Leaving the Wallpapers tab pauses the pool AT ONCE but frees its decoders only after a grace
// period, so a user who taps straight back does not pay for a teardown they made pointless.
//
// Measured on a Nothing A001 before this existed: every return to the tab cost three ExoPlayer
// releases, three fresh MediaCodec instantiations and 430 ms with no frame on the video surface —
// 10.4% of frames over 33 ms across a tab-switch window against 3.9% idle.
//
// The three release paths that must stay IMMEDIATE are the point of the split: the apply flow
// AWAITS a release so the OS finds decoders free, backgrounding hands them to the OEM live-wallpaper
// chooser, and detach() is a teardown. Only a tab switch can be undone, so only it is deferred.
//
// The observable here is `notifyListeners()`: releaseDecoders() fires it (cards re-read slotForIndex
// and fall back to their poster), releaseDecodersOnLeave() does not. So a notification means the
// teardown actually ran. The pause half needs players in the pool to observe and is covered on
// device, not here.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/features/wallpapers/data/feed_video_player.dart';
import 'package:arul/features/wallpapers/data/wallpaper_prefetch_service.dart';
import 'package:arul/features/wallpapers/presentation/video_preload_controller.dart';

const _method = MethodChannel('arul_test/feed_video_grace');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VideoPreloadController controller;
  late int teardowns;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_method, (call) async => null);
    controller = VideoPreloadController(
      cdnBaseUrl: 'https://cdn.test',
      prefetch: WallpaperPrefetchService(cdnBaseUrl: 'https://cdn.test'),
      pool: FeedVideoPlayerPool.withChannels(
        _method,
        const EventChannel('arul_test/feed_video_grace_events'),
      ),
    );
    teardowns = 0;
    controller.addListener(() => teardowns++);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_method, null);
      controller.dispose();
    });
  });

  testWidgets('leaving holds the decoders through the grace — the tab switch '
      'the user is most likely to undo costs nothing', (tester) async {
    controller.releaseDecodersOnLeave();
    await tester.pump(const Duration(seconds: 1));

    expect(teardowns, 0);
    // Drain it: the assertion above is the test, and a timer left pending fails teardown.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('staying away frees them — budget SoCs hold only a handful, and '
      'that invariant is deferred, never dropped', (tester) async {
    controller.releaseDecodersOnLeave();
    await tester.pump(const Duration(seconds: 4));

    expect(teardowns, 1);
  });

  testWidgets('returning inside the grace cancels it, so the pool is never '
      'emptied and coming back is a resume', (tester) async {
    controller.releaseDecodersOnLeave();
    await tester.pump(const Duration(seconds: 1));
    controller.reclaimDecoders();
    final afterReturn = teardowns;
    // Well past the grace: a surviving timer would have fired by here.
    await tester.pump(const Duration(seconds: 10));

    expect(
      teardowns,
      afterReturn,
      reason: 'a trip the user did not make must cost nothing',
    );
  });

  testWidgets('an immediate release supersedes a pending one — the apply flow '
      'AWAITS one, so a timer must not fire into the pool behind it', (
    tester,
  ) async {
    controller.releaseDecodersOnLeave();
    await controller.releaseDecoders();
    expect(teardowns, 1, reason: 'the immediate release ran');

    await tester.pump(const Duration(seconds: 10));

    expect(teardowns, 1, reason: 'and the superseded timer never ran a second');
  });
}
