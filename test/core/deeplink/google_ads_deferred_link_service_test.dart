import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/core/deeplink/google_ads_deferred_link_service.dart';
import 'package:arul/features/referral/data/install_referrer_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = '95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f';

  tearDown(ArulDeepLink.reset);

  group('parseWallpaperId', () {
    test('accepts the verified wallpaper URL and normalizes the UUID', () {
      expect(
        GoogleAdsDeferredLinkService.parseWallpaperId(
          'https://arul.hsrutility.com/w/${id.toUpperCase()}?utm_source=google',
        ),
        id,
      );
    });

    test('accepts a trailing slash, as android.net.Uri does', () {
      // Native drops empty path segments, so a campaign App URL ending in "/"
      // clears the Kotlin check. Rejecting it here would strand the delivery on
      // the far side of the channel with nothing logged.
      expect(
        GoogleAdsDeferredLinkService.parseWallpaperId(
          'https://arul.hsrutility.com/w/$id/',
        ),
        id,
      );
    });

    test('rejects another host, scheme, path, or malformed UUID', () {
      for (final link in <String?>[
        null,
        '',
        'http://arul.hsrutility.com/w/$id',
        'https://evil.example/w/$id',
        'https://arul.hsrutility.com/not-w/$id',
        'https://arul.hsrutility.com/w/not-a-uuid',
        'https://arul.hsrutility.com/w/$id/extra',
      ]) {
        expect(
          GoogleAdsDeferredLinkService.parseWallpaperId(link),
          isNull,
          reason: 'must reject $link',
        );
      }
    });
  });

  test('initial native payload is persisted, handed live, and ACKed', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const channel = MethodChannel('test/google_ads_deferred_link');
    final calls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getDeferredDeepLink') {
            return {
              'url': 'https://arul.hsrutility.com/w/$id',
              'token': '123:test',
            };
          }
          if (call.method == 'ackDeferredDeepLink') return true;
          return null;
        });

    final service = GoogleAdsDeferredLinkService(
      InstallReferrerService(prefs),
      channel: channel,
    );
    await service.start();

    expect(prefs.getString('pending_deeplink_wallpaper'), id);
    expect(ArulDeepLink.consume(), id);
    expect(calls.map((call) => call.method), [
      'getDeferredDeepLink',
      'ackDeferredDeepLink',
    ]);
    expect(calls.last.arguments, {'token': '123:test'});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a token already seen is not re-queued or re-ACKed', () async {
    // Native pushes on capture AND answers the initial pull with the same
    // payload, so seeing one delivery twice is the normal case, not an error.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const channel = MethodChannel('test/google_ads_deferred_link_repeat');
    const payload = {
      'url': 'https://arul.hsrutility.com/w/$id',
      'token': 'https://arul.hsrutility.com/w/$id',
    };
    final calls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getDeferredDeepLink') return payload;
          if (call.method == 'ackDeferredDeepLink') return true;
          return null;
        });

    final service = GoogleAdsDeferredLinkService(
      InstallReferrerService(prefs),
      channel: channel,
    );
    await service.start();
    ArulDeepLink.consume();
    // Native still holds the delivery if its own ACK write lost a race, so a
    // second pull returning the same payload has to be inert.
    await service.start();

    expect(calls.where((c) => c.method == 'ackDeferredDeepLink'), hasLength(1));
    expect(
      ArulDeepLink.consume(),
      isNull,
      reason: 'a second delivery of the same token must not re-open the feed',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
