// What a reel may do while nobody can see or hear it. The status pool is audible, so a play() off
// screen is sound from nowhere; a decoder claimed off screen starves the reel that IS on screen.
// A focus loss (another app took the speaker, headphones out) holds the clip until a tap on it.
import 'package:arul/app/widgets/reel/reel_item.dart';
import 'package:arul/app/widgets/reel/reel_prefetch_service.dart';
import 'package:arul/app/widgets/reel/video_preload_controller.dart';
import 'package:arul/features/wallpapers/data/feed_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _Clip implements ReelItem {
  const _Clip(this.id);

  @override
  final String id;

  @override
  String? videoUrl(String cdnBase) => '$cdnBase/clips/$id.mp4';

  @override
  String posterUrl(String cdnBase) => '$cdnBase/thumbs/$id.jpg';
}

/// A real CacheManager starts disk work in its constructor; nothing here ever calls it.
class _NullCache implements CacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Never touches a disk cache -> every open goes straight to the url, synchronously enough to test.
class _NoCache extends ReelPrefetchService<_Clip> {
  _NoCache()
    : super(
        cdnBaseUrl: 'https://cdn.test',
        cache: _NullCache.new,
        ahead: 1,
        aheadCold: 1,
      );

  @override
  Future<String?> cachedPathOrNull(String url) async => null;

  @override
  Future<String?> ensureCached(String url, {bool priority = false}) async =>
      null;

  @override
  void prefetchAround(List<_Clip> items, int currentIndex) {}
}

const _method = MethodChannel('arul_test/reel_video');
const _events = EventChannel('arul_test/reel_video_events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late VideoPreloadController<_Clip> controller;
  MockStreamHandlerEventSink? sink;
  var nextId = 1;

  const clips = [_Clip('a'), _Clip('b'), _Clip('c')];

  /// Every open/play that asked the native player to make sound.
  Iterable<MethodCall> plays() => calls.where(
    (c) =>
        c.method == 'play' ||
        (c.method == 'open' && (c.arguments as Map)['playWhenReady'] == true),
  );

  VideoPreloadController<_Clip> build({required bool visible}) {
    final c = VideoPreloadController<_Clip>(
      cdnBaseUrl: 'https://cdn.test',
      prefetch: _NoCache(),
      pool: FeedVideoPlayerPool.withChannels(_method, _events),
      keepBehind: 0,
      audio: true,
      visible: visible,
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    calls = [];
    nextId = 1;
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        final id = nextId++;
        return {'playerId': id, 'textureId': 100 + id};
      }
      return null;
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (_, s) {
          sink = s;
        },
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
    });
  });

  testWidgets('hidden: no decoder is claimed and nothing plays', (
    tester,
  ) async {
    controller = build(visible: false);
    controller.setItems(clips);
    await tester.pump(const Duration(milliseconds: 500));

    expect(calls.where((c) => c.method == 'create'), isEmpty);
    expect(plays(), isEmpty);
  });

  testWidgets('shown: the current clip opens playing, its neighbour paused, '
      'inside the two-player pool', (tester) async {
    controller = build(visible: false);
    controller.setItems(clips);
    controller.visible = true;
    await tester.pump(const Duration(milliseconds: 500));

    expect(calls.where((c) => c.method == 'create'), hasLength(2));
    final opens = calls.where((c) => c.method == 'open').toList();
    expect(opens, hasLength(2));
    expect(plays(), hasLength(1), reason: 'only the current card plays');
  });

  testWidgets('a resume from the background while hidden never plays', (
    tester,
  ) async {
    controller = build(visible: true);
    controller.setItems(clips);
    await tester.pump(const Duration(milliseconds: 500));

    controller
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.paused)
      ..visible = false;
    calls.clear();
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      plays(),
      isEmpty,
      reason: 'backgrounded on Status, came back on Wallpapers',
    );
    expect(calls.where((c) => c.method == 'create'), isEmpty);
  });

  testWidgets('hiding pauses at once', (tester) async {
    controller = build(visible: true);
    controller.setItems(clips);
    await tester.pump(const Duration(milliseconds: 500));
    calls.clear();

    controller.visible = false;
    await tester.pump();

    expect(calls.where((c) => c.method == 'pause'), isNotEmpty);
    expect(plays(), isEmpty);
  });

  testWidgets('a focus loss holds the clip through every reconcile until a '
      'tap on the card', (tester) async {
    controller = build(visible: true);
    controller.setItems(clips);
    await tester.pump(const Duration(milliseconds: 500));
    final current =
        calls
                .firstWhere(
                  (c) =>
                      c.method == 'open' &&
                      (c.arguments as Map)['playWhenReady'] == true,
                )
                .arguments
            as Map;

    // Platform events cross a real async gap the fake clock does not drive.
    await tester.runAsync(() async {
      sink!.success({'playerId': current['playerId'], 'event': 'focusLost'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(controller.isHeld, isTrue);
    calls.clear();

    // A swipe back and forth, a background round trip: none of it restarts the sound.
    await controller.onPageChanged(1);
    await controller.onPageChanged(0);
    await tester.pump(const Duration(milliseconds: 500));
    controller
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 500));
    expect(plays(), isEmpty);

    controller.toggleHeldByUser();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.isHeld, isFalse);
    expect(plays(), isNotEmpty, reason: 'the tap is the one way out');
  });

  testWidgets('a tap pauses a playing clip; a swipe lets the next one play', (
    tester,
  ) async {
    controller = build(visible: true);
    controller.setItems(clips);
    await tester.pump(const Duration(milliseconds: 500));

    controller.toggleHeldByUser();
    expect(controller.isHeld, isTrue);
    calls.clear();
    await controller.onPageChanged(1);
    await tester.pump(const Duration(milliseconds: 500));

    expect(controller.isHeld, isFalse);
    expect(plays(), isNotEmpty);
  });
}
