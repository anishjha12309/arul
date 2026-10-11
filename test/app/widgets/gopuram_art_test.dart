// Loading and empty states draw the premium screens' detailed gopuram, never the blocky mark the
// owner asked to retire from them.

import 'dart:io';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/widgets/gopuram_art.dart';
import 'package:arul/app/widgets/gopuram_mark.dart';
import 'package:arul/features/ringtones/presentation/ringtone_states.dart';
import 'package:arul/features/wallpapers/presentation/feed_states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  test('the art ships in a bundled folder', () {
    expect(File(GopuramArt.asset).existsSync(), isTrue);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/images/\n'));
  });

  testWidgets('the feed loading card draws the detailed gopuram', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const FeedLoading(margin: EdgeInsets.zero, radius: 20)),
    );
    expect(find.byType(GopuramArt), findsOneWidget);
    expect(find.byType(GopuramMark), findsNothing);
  });

  testWidgets('a card waiting on its poster draws the same gopuram', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const ReelPosterPlaceholder()));
    expect(find.byType(GopuramArt), findsOneWidget);
    expect(find.byType(GopuramMark), findsNothing);
  });

  testWidgets('the feed and ringtone empty states draw it too', (tester) async {
    await tester.pumpWidget(_host(FeedEmpty(onBrowseAll: () {})));
    expect(find.byType(GopuramArt), findsOneWidget);

    await tester.pumpWidget(_host(const RingtonesEmpty()));
    expect(find.byType(GopuramArt), findsOneWidget);
    expect(find.byType(GopuramMark), findsNothing);
  });
}
