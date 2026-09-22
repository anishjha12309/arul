import 'package:arul/app/widgets/arul_spinner.dart';
import 'package:arul/core/config/build_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the REST path of the branded spinner, which no other test reaches.
///
/// `reduceMotion` is true on a low-tier phone and under battery saver, so the rest path is what a
/// large part of the install base actually renders — and it shipped a defect no green suite could
/// see: the controller is `late final`, the rest path never read it, and `dispose()` became its
/// first read, constructing a ticker against an already-defunct element.
/// A mount-then-unmount under each of the two signals is the whole test.
void main() {
  Widget host(Widget child, {bool disableAnimations = false}) => MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child),
    ),
  );

  tearDown(DeviceQuality.resetForTesting);

  testWidgets('rest path survives an unmount when animations are disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const ArulSpinner(size: 20), disableAnimations: true),
    );
    expect(find.byType(ArulSpinner), findsOneWidget);
    // The unmount is the assertion: a controller first constructed here would look up an
    // InheritedWidget on a defunct element and throw.
    await tester.pumpWidget(host(const SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rest path survives an unmount on a low-tier device', (
    tester,
  ) async {
    DeviceQuality.debugSetTier(DeviceTier.low);
    await tester.pumpWidget(host(const ArulSpinner(size: 20)));
    expect(find.byType(ArulSpinner), findsOneWidget);
    await tester.pumpWidget(host(const SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('spinning path still survives an unmount', (tester) async {
    DeviceQuality.debugSetTier(DeviceTier.high);
    await tester.pumpWidget(host(const ArulSpinner(size: 20)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(host(const SizedBox.shrink()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('honours the size it is given', (tester) async {
    DeviceQuality.debugSetTier(DeviceTier.high);
    await tester.pumpWidget(host(const ArulSpinner(size: 14)));
    expect(tester.getSize(find.byType(ArulSpinner)), const Size(14, 14));
    await tester.pumpWidget(host(const SizedBox.shrink()));
  });
}
