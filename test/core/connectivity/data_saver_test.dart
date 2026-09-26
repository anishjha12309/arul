// DataSaver is read synchronously by the prefetcher, so it caches the native answer and re-asks
// in the background; a missing or failing channel must never read as ON.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/connectivity/data_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.hsrutility.arul/build_info');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    DataSaver.debugSet(null);
  });

  test('reads the native answer', () async {
    var asks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'dataSaverOn') return null;
      asks++;
      return true;
    });
    DataSaver.debugSet(null);
    expect(DataSaver.isOn, isFalse, reason: 'unknown reads as off');
    await DataSaver.refresh();
    expect(DataSaver.isOn, isTrue);
    expect(asks, 1, reason: 'a fresh answer is not re-asked');
  });

  test('a failing channel keeps it off', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    DataSaver.debugSet(null);
    expect(await DataSaver.refresh(), isFalse);
  });

  test('concurrent refreshes share one ask', () async {
    var asks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      asks++;
      return false;
    });
    DataSaver.debugSet(null);
    await Future.wait([DataSaver.refresh(), DataSaver.refresh()]);
    expect(asks, 1);
  });
}
