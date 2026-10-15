// The kind strings only match MediaPickChannel at runtime: a typo is a wrong picker, not an error.

import 'package:arul/features/upload/data/media_pick_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each kind sends the wire value MediaPickChannel matches on', () async {
    const channel = MethodChannel('test/media_pick');
    final kinds = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          kinds.add((call.arguments as Map<Object?, Object?>)['kind']);
          return null;
        });
    const picker = MediaPickService(channel: channel);

    for (final kind in MediaPickKind.values) {
      expect(await picker.pick(kind), isNull);
    }

    expect(kinds, ['visual', 'video', 'audio', 'image']);
  });
}
