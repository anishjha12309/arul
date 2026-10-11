// The upload form after the redesign: a three-way kind switch (Status included), ONE category select
// field opening a sheet instead of a wrap of chips, and a submit that waits for file, category and
// rights. Status categories are languages, read off the status catalog only once the Status tab
// fetched it.

import 'dart:async';
import 'dart:io';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/app/theme/theme.dart';
import 'package:arul/app/widgets/arul_chip.dart';
import 'package:arul/app/widgets/cta_button.dart';
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:arul/features/upload/data/media_pick_service.dart';
import 'package:arul/features/upload/data/video_prep_service.dart';
import 'package:arul/features/upload/domain/video_plan.dart';
import 'package:arul/features/upload/presentation/upload_screen.dart';
import 'package:arul/features/upload/providers/upload_provider.dart';
import 'package:arul/features/wallpapers/providers/catalog_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pickChannel = MethodChannel(MediaPickService.channelName);

late SharedPreferences _prefs;

/// Holds each preparation open until the test resolves it, and records cancels.
class _FakePrep implements VideoPrepService {
  Completer<PreparedVideo>? pending;
  void Function(double progress)? progress;
  VideoTarget? target;
  int cancels = 0;
  Object? failWith;

  @override
  Future<PreparedVideo> prepare(
    String path,
    VideoTarget target, {
    void Function(double progress)? onProgress,
  }) {
    this.target = target;
    if (failWith case final error?) return Future.error(error);
    progress = onProgress;
    return (pending = Completer<PreparedVideo>()).future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final open = pending;
    if (open != null && !open.isCompleted) {
      open.completeError(const VideoPrepException(VideoPrepFailure.cancelled));
    }
  }
}

Future<void> _pump(
  WidgetTester tester, {
  VideoPrepService? prep,
  List<WallpaperCategory> wallpaperCategories = const [
    WallpaperCategory('murugan', 'Murugan'),
    WallpaperCategory('sivan', 'Sivan'),
    WallpaperCategory('swarnakarshanabhairava', 'Swarnakarshanabhairava'),
  ],
}) async {
  // The A001's screen: the whole form, CTA and footnote included, is built without scrolling.
  tester.view.physicalSize = const Size(1080, 2392);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        categoriesProvider.overrideWithValue(wallpaperCategories),
        if (prep != null) videoPrepServiceProvider.overrideWithValue(prep),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ArulTheme.dark(),
        home: const UploadScreen(),
      ),
    ),
  );
  await tester.pump();
}

CtaButton _submit(WidgetTester tester) =>
    tester.widget<CtaButton>(find.byType(CtaButton));

/// Answers the picker with a real file on disk, so the screen's size check reads real bytes.
File _answerPickWith(String name, {int bytes = 2048}) {
  final dir = Directory.systemTemp.createTempSync('upload_test');
  final file = File('${dir.path}/$name')
    ..writeAsBytesSync(List.filled(bytes, 7));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        _pickChannel,
        (call) async => {'path': file.path, 'name': name},
      );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickChannel, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return file;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets(
    'offers Wallpaper, Ringtone and Status, and Status asks for a video',
    (tester) async {
      await _pump(tester);

      expect(find.text('Wallpaper'), findsOneWidget);
      expect(find.text('Ringtone'), findsOneWidget);
      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Choose an image or video'), findsOneWidget);

      await tester.tap(find.text('Status'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a video'), findsOneWidget);
      expect(
        find.text(
          'Approved status videos appear in the Status tab with your name',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'categories are one select field and a sheet, never a wrap of chips',
    (tester) async {
      await _pump(tester);

      expect(find.byType(ArulChip), findsNothing);
      expect(find.text('Choose a category'), findsOneWidget);

      await tester.tap(find.text('Choose a category'));
      await tester.pumpAndSettle();

      // The sheet lists every category, the longest name included, on its own card.
      expect(find.text('Murugan'), findsOneWidget);
      expect(find.text('Swarnakarshanabhairava'), findsOneWidget);

      await tester.tap(find.text('Sivan'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a category'), findsNothing);
      expect(find.text('Sivan'), findsOneWidget);
    },
  );

  testWidgets('switching kind clears the category, which belongs to one kind', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Choose a category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Murugan'));
    await tester.pumpAndSettle();
    expect(find.text('Murugan'), findsOneWidget);

    await tester.tap(find.text('Ringtone'));
    await tester.pumpAndSettle();

    expect(find.text('Murugan'), findsNothing);
    expect(find.text('Choose a category'), findsOneWidget);
  });

  testWidgets(
    'Status offers its languages without fetching the status catalog',
    (tester) async {
      await _pump(tester);

      await tester.tap(find.text('Status'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a category'));
      await tester.pumpAndSettle();

      expect(find.text('Tamil'), findsOneWidget);
      expect(find.text('Telugu'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(UploadScreen)),
      );
      expect(container.exists(statusCatalogProvider), isFalse);
    },
  );

  testWidgets('submit waits for a file, a category and the rights box', (
    tester,
  ) async {
    _answerPickWith('kolam.jpg');
    await _pump(tester);
    expect(_submit(tester).onPressed, isNull);

    await tester.tap(find.text('Choose an image or video'));
    await tester.pumpAndSettle();
    // The card now shows the file, what it is, and a way to change it.
    expect(find.text('kolam.jpg'), findsOneWidget);
    expect(find.text('JPG · 2 KB'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
    expect(_submit(tester).onPressed, isNull);

    await tester.tap(find.text('Choose a category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sivan'));
    await tester.pumpAndSettle();
    expect(_submit(tester).onPressed, isNull);

    await tester.tap(
      find.text(
        'I own the rights to this content or have permission to share it',
      ),
    );
    await tester.pump();
    expect(_submit(tester).onPressed, isNotNull);
  });

  testWidgets('a picked image over the cap is refused and never shown', (
    tester,
  ) async {
    _answerPickWith('huge.png', bytes: 10 * 1024 * 1024 + 1);
    await _pump(tester);

    await tester.tap(find.text('Choose an image or video'));
    await tester.pumpAndSettle();

    expect(find.text('huge.png'), findsNothing);
    expect(find.text('File is too large (max 10MB).'), findsOneWidget);
  });

  testWidgets(
    'a Status video is prepared on the phone, shows its progress, then the MP4',
    (tester) async {
      final prep = _FakePrep();
      _answerPickWith('VID_20261011.mov');
      final out = File(
        '${Directory.systemTemp.createTempSync('prep').path}/out.mp4',
      )..writeAsBytesSync(List.filled(16, 1));
      await _pump(tester, prep: prep);

      await tester.tap(find.text('Status'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a video'));
      await tester.pump();
      prep.progress?.call(0.4);
      await tester.pump();

      expect(prep.target, VideoTarget.status);
      expect(find.text('VID_20261011.mov'), findsOneWidget);
      expect(find.text('Getting your video ready… 40%'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(_submit(tester).onPressed, isNull);

      prep.pending?.complete(
        PreparedVideo(
          path: out.path,
          width: 1024,
          height: 1824,
          durationMs: 28400,
          bytes: 6396314,
          converted: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('VID_20261011.mp4'), findsOneWidget);
      expect(find.text('MP4 · 0:28 · 6.1 MB'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    },
  );

  testWidgets('a Status video with no sound is refused with the reason', (
    tester,
  ) async {
    final prep = _FakePrep()
      ..failWith = const VideoPrepException(VideoPrepFailure.noAudio);
    _answerPickWith('silent.mp4');
    await _pump(tester, prep: prep);

    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a video'));
    await tester.pumpAndSettle();

    expect(
      find.text('This video has no sound. A status needs music.'),
      findsOneWidget,
    );
    expect(find.text('silent.mp4'), findsNothing);
    expect(find.text('Choose a video'), findsOneWidget);
  });

  testWidgets('Cancel stops the preparation and empties the card', (
    tester,
  ) async {
    final prep = _FakePrep();
    _answerPickWith('long.mp4');
    await _pump(tester, prep: prep);

    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a video'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(prep.cancels, 1);
    expect(find.text('long.mp4'), findsNothing);
    expect(find.text('Choose a video'), findsOneWidget);
  });

  testWidgets('a live wallpaper video is prepared for the live target', (
    tester,
  ) async {
    final prep = _FakePrep();
    _answerPickWith('loop.mp4');
    await _pump(tester, prep: prep);

    await tester.tap(find.text('Choose an image or video'));
    await tester.pump();

    expect(prep.target, VideoTarget.liveWallpaper);
    await prep.cancel();
    await tester.pumpAndSettle();
  });
}
