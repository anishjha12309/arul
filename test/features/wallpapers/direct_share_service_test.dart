// The direct-share channel's new calls, against a fake platform side: a false or a throw is routine
// and never reaches the caller as an error.
import 'package:arul/features/wallpapers/data/direct_share_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('arul_test/direct_share');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  void answer(Object? Function(MethodCall call) reply) {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return reply(call);
        });
  }

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  const service = DirectShareService(_channel);

  group('hasWhatsApp', () {
    test('Business alone counts', () async {
      answer((call) => call.arguments['package'] == 'com.whatsapp.w4b');

      expect(await service.hasWhatsApp(mimeType: 'video/mp4'), isTrue);
      expect(calls.map((c) => c.arguments['package']), [
        'com.whatsapp',
        'com.whatsapp.w4b',
      ]);
      expect(calls.first.method, 'canShareToPackage');
      expect(calls.first.arguments['mimeType'], 'video/mp4');
    });

    test('a refused package moves on to the next', () async {
      answer((call) {
        if (call.arguments['package'] == 'com.whatsapp') {
          throw PlatformException(code: 'bad_input');
        }
        return true;
      });

      expect(await service.hasWhatsApp(mimeType: 'video/mp4'), isTrue);
      expect(calls, hasLength(2));
    });

    test('neither installed -> false', () async {
      answer((_) => false);

      expect(await service.hasWhatsApp(mimeType: 'video/mp4'), isFalse);
    });

    test('no channel at all -> false, never a throw', () async {
      expect(
        await const DirectShareService(
          MethodChannel('arul_test/absent'),
        ).hasWhatsApp(mimeType: 'video/mp4'),
        isFalse,
      );
    });
  });

  group('sendToStatus', () {
    test('passes the clip and its type', () async {
      answer((_) => true);

      expect(
        await service.sendToStatus(filePath: '/c/s.mp4', mimeType: 'video/mp4'),
        isTrue,
      );
      expect(calls.single.method, 'sendToStatus');
      expect(calls.single.arguments, {
        'filePath': '/c/s.mp4',
        'mimeType': 'video/mp4',
      });
    });

    test('a platform error is a plain false', () async {
      answer((_) => throw PlatformException(code: 'bad_input'));

      expect(
        await service.sendToStatus(filePath: '/c/s.mp4', mimeType: 'video/mp4'),
        isFalse,
      );
    });
  });
}
