// A translation that overflows shows in plain English instead, never shrunk or cut.
import 'package:arul/app/widgets/arul_screen_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, String title) async {
  await tester.binding.setSurfaceSize(const Size(360, 640));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: ArulScreenHeader(title: title, fallbackTitle: 'Status and Greet'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a translation too wide for the band gives way to English', (
    tester,
  ) async {
    await _pump(tester, 'ஸ்டேட்டஸ் & வாழ்த்து ஸ்டேட்டஸ்');
    expect(find.text('Status and Greet'), findsOneWidget);
    expect(find.textContaining('ஸ்டேட்டஸ்'), findsNothing);
  });

  testWidgets('a translation that fits stays, at full size', (tester) async {
    await _pump(tester, 'Short');
    expect(find.text('Short'), findsOneWidget);
    final fitted = tester.getSize(find.byType(FittedBox));
    final text = tester.getSize(find.text('Short'));
    expect(fitted.width, text.width);
  });
}
