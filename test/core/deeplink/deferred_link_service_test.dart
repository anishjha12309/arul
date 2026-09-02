// The native -> Dart bridge for links fetched over the network after an ad install (GA4F, the Meta SDK).
// The payload is persisted BEFORE it is ACKed -> the ACK is the commit point.
// A token seen twice is inert, and the source rides through to the target.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/deeplink/deferred_link_service.dart';
import 'package:arul/features/referral/data/install_referrer_service.dart';

const _w = '95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f';
const _r = '0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(ArulDeepLink.reset);

  /// Wires a mock native side that answers the initial pull with [initial]
  /// and records every call; returns the started service + the call log.
  Future<({List<MethodCall> calls, SharedPreferences prefs})> start(
    String channelName,
    List<Map<String, Object?>> initial,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final channel = MethodChannel(channelName);
    final calls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getDeferredDeepLinks') return initial;
          if (call.method == 'ackDeferredDeepLink') return true;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await DeferredLinkService(
      InstallReferrerService(prefs),
      channel: channel,
    ).start();
    return (calls: calls, prefs: prefs);
  }

  test('a Google Ads App URL is persisted, handed live, and ACKed', () async {
    final h = await start('test/deferred_link_google', [
      {
        'url': 'https://arul.hsrutility.com/w/$_w?lang=hi',
        'token': 'https://arul.hsrutility.com/w/$_w?lang=hi',
        'source': 'google_ads',
      },
    ]);

    expect(h.prefs.getString('pending_deeplink_wallpaper'), _w);
    expect(h.prefs.getString('pending_deeplink_source'), 'google_ads');
    expect(h.prefs.getString('pending_deeplink_lang'), 'hi');
    expect(
      ArulDeepLink.consumeWallpaper(),
      const WallpaperLinkTarget(_w, source: DeepLinkSource.googleAds),
    );
    expect(ArulDeepLink.consumeLocale(), 'hi');
    expect(h.calls.map((c) => c.method), [
      'getDeferredDeepLinks',
      'ackDeferredDeepLink',
    ]);
    expect(h.calls.last.arguments, {
      'token': 'https://arul.hsrutility.com/w/$_w?lang=hi',
    });
  });

  test(
    "a Meta deferred link in the reference's scheme form resolves",
    () async {
      const url =
          'fb875866992041168://open?screen=ringtones&ringtone_id=$_r&lang=ta';
      final h = await start('test/deferred_link_meta', [
        {'url': url, 'token': url, 'source': 'meta'},
      ]);

      expect(h.prefs.getString('pending_deeplink_ringtone'), _r);
      expect(h.prefs.getString('pending_deeplink_wallpaper'), isNull);
      expect(
        ArulDeepLink.consumeRingtone(),
        const RingtoneLinkTarget(_r, source: DeepLinkSource.meta),
      );
      expect(ArulDeepLink.consumeLocale(), 'ta');
    },
  );

  test('a link pushed by native AFTER start lands the same way', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const channel = MethodChannel('test/deferred_link_push');
    final acks = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getDeferredDeepLinks') return <Object?>[];
          if (call.method == 'ackDeferredDeepLink') acks.add(call.arguments);
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await DeferredLinkService(
      InstallReferrerService(prefs),
      channel: channel,
    ).start();

    // Simulate native's invokeMethod("onDeferredDeepLink", …) into Dart.
    const url = 'https://arul.hsrutility.com/r/$_r';
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('onDeferredDeepLink', {
              'url': url,
              'token': url,
              'source': 'google_ads',
            }),
          ),
          (_) {},
        );

    expect(prefs.getString('pending_deeplink_ringtone'), _r);
    expect(acks, [
      {'token': url},
    ]);
  });

  test('a token already seen is not re-queued or re-ACKed', () async {
    // Native pushes on capture AND answers the initial pull with the same payload -> one delivery seen twice is normal.
    const url = 'https://arul.hsrutility.com/w/$_w';
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const channel = MethodChannel('test/deferred_link_repeat');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getDeferredDeepLinks') {
            return [
              {'url': url, 'token': url, 'source': 'google_ads'},
            ];
          }
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final service = DeferredLinkService(
      InstallReferrerService(prefs),
      channel: channel,
    );
    await service.start();
    ArulDeepLink.consumeWallpaper();
    // Native still holds the delivery if its ACK write lost a race -> a second pull of the same payload must be inert.
    await service.start();

    expect(calls.where((c) => c.method == 'ackDeferredDeepLink'), hasLength(1));
    expect(
      ArulDeepLink.consumeWallpaper(),
      isNull,
      reason: 'a second delivery of the same token must not re-open the feed',
    );
  });

  test('a URL that is not ours is ACKed and dropped, never queued', () async {
    // Leaving a rejected payload pending would retry it forever on every Activity creation.
    final h = await start('test/deferred_link_junk', [
      {
        'url': 'https://evil.example/w/$_w',
        'token': 'https://evil.example/w/$_w',
        'source': 'google_ads',
      },
    ]);
    expect(h.prefs.getString('pending_deeplink_wallpaper'), isNull);
    expect(ArulDeepLink.pendingTarget, isNull);
    expect(h.calls.map((c) => c.method), contains('ackDeferredDeepLink'));
  });

  test('a payload with no token is ignored', () async {
    final h = await start('test/deferred_link_notoken', [
      {'url': 'https://arul.hsrutility.com/w/$_w', 'token': ''},
    ]);
    expect(ArulDeepLink.pendingTarget, isNull);
    expect(h.calls.map((c) => c.method), ['getDeferredDeepLinks']);
  });
}
