// Pins RingtonesLoading's `_SkeletonRow` to RingtoneRow's real geometry (W9) -> a skeleton that is
// merely the right HEIGHT still pops the title/subtitle/controls sideways when the real row lands.
// Both are pumped in the SAME harness at the SAME width so their rects are directly comparable.
//
// Not every element can be pixel-matched, and this file does not pretend otherwise:
//   - the title and subtitle bars match the real text's ORIGIN and HEIGHT, never its WIDTH -> a
//     title is catalog data of arbitrary length (RingtoneRow.innerHeightFor reserves room for a
//     full two-line title so a long one never resizes the row); no fixed bar can equal an arbitrary
//     string's glyph width, and a skeleton has no string to measure in advance.
//   - the Set pill's LEFT edge and width are the same kind of case: `_SetPill` (ringtones_screen.dart)
//     reserves no fixed width at all -- it sizes to "Set"'s own glyphs, which vary by locale. Its
//     RIGHT edge is still asserted, because the row's single Expanded (the title column) absorbs all
//     the slack, which makes the LAST child's right edge flush with the row's own content edge no
//     matter how wide that child is.
//   - the play control's X-origin follows from the same fact: it sits between the Expanded and the
//     Set pill, so its position shifts with whatever the Set pill measures as. Its Y and its 44x44
//     size are asserted; its X is not.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/data/models/ringtone.dart';
import 'package:arul/features/ringtones/presentation/ringtone_states.dart';
import 'package:arul/features/ringtones/presentation/ringtone_tile.dart';
import 'package:arul/features/ringtones/presentation/ringtones_screen.dart';
import 'package:arul/features/ringtones/providers/ringtone_preview_provider.dart';
import 'package:arul/theme/arul_tokens.dart';

/// Idle, always -> the real notifier owns a `just_audio` player that needs a platform. RingtoneRow
/// only reads `isPlayingId`/`isLoadingId` off the state, so idle is enough to render its RESTING
/// look, the one the skeleton stands in for (a now-playing row is a different, taller-tinted state).
class _IdlePreview extends RingtonePreviewNotifier {
  @override
  RingtonePreviewState build() => const RingtonePreviewState();
}

/// Short on purpose -> long enough to be real catalog content, short enough to render as ONE line at
/// the width this test gives it. A two-line title is still handled (RingtoneRow reserves room for
/// one), just not what this test compares -- see the file header.
final _ringtone = const Ringtone(
  id: 'rt-geometry',
  title: 'Muruga',
  category: 'murugan',
  deity: 'murugan',
  audioKey: 'preview.mp3',
);

const _kRowKey = Key('ringtoneSkeletonRow');
const _kArtKey = Key('ringtoneSkeletonArt');
const _kTitleKey = Key('ringtoneSkeletonTitle');
const _kSubtitleKey = Key('ringtoneSkeletonSubtitle');
const _kPlayKey = Key('ringtoneSkeletonPlay');
const _kSetKey = Key('ringtoneSkeletonSet');

void main() {
  Future<void> sized(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget shell(Widget child) => ProviderScope(
    overrides: [ringtonePreviewProvider.overrideWith(_IdlePreview.new)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );

  /// Origin (left, top) and HEIGHT only -> the metrics that stop the row jumping. Width is asserted
  /// separately, only for the elements where it is actually deterministic (see the file header).
  void expectOriginAndHeight(Rect skeleton, Rect loaded, String what) {
    expect(
      skeleton.left,
      closeTo(loaded.left, 1.0),
      reason: '$what: left edge',
    );
    expect(skeleton.top, closeTo(loaded.top, 1.0), reason: '$what: top edge');
    expect(
      skeleton.height,
      closeTo(loaded.height, 1.0),
      reason: '$what: height',
    );
  }

  /// Full rect -> for elements that are fixed-size chrome on BOTH sides, with no content driving
  /// their footprint (just the art square: it is the FIRST row child, so nothing upstream of it can
  /// move its origin either).
  void expectFullRect(Rect skeleton, Rect loaded, String what) {
    expectOriginAndHeight(skeleton, loaded, what);
    expect(skeleton.width, closeTo(loaded.width, 1.0), reason: '$what: width');
  }

  /// Top + size, never X -> for the play control. It is a fixed 44x44 box on BOTH sides, but its
  /// HORIZONTAL position is inherited from the Set pill's content-driven width (see the file header),
  /// so only what is actually deterministic here is asserted.
  void expectSizeAndTop(Rect skeleton, Rect loaded, String what) {
    expect(skeleton.top, closeTo(loaded.top, 1.0), reason: '$what: top edge');
    expect(skeleton.width, closeTo(loaded.width, 1.0), reason: '$what: width');
    expect(
      skeleton.height,
      closeTo(loaded.height, 1.0),
      reason: '$what: height',
    );
  }

  testWidgets('skeleton row geometry matches the loaded row within a pixel', (
    tester,
  ) async {
    await sized(tester, 390);

    // ── Skeleton: RingtonesLoading renders 7 rows -> `.first` is the topmost, the one a user
    // actually sees land. ────────────────────────────────────────────────────────────────────
    await tester.pumpWidget(shell(const RingtonesLoading()));
    await tester.pump(const Duration(milliseconds: 30));

    final skeletonRow = tester.getRect(find.byKey(_kRowKey).first);
    final skeletonArt = tester.getRect(find.byKey(_kArtKey).first);
    final skeletonTitle = tester.getRect(find.byKey(_kTitleKey).first);
    final skeletonSubtitle = tester.getRect(find.byKey(_kSubtitleKey).first);
    final skeletonPlay = tester.getRect(find.byKey(_kPlayKey).first);
    final skeletonSet = tester.getRect(find.byKey(_kSetKey).first);

    // ── Loaded: ONE real row, in the SAME left/top padding RingtonesLoading uses (screenPadding
    // horizontal, zero top -> AppShell.dockClearance is a bottom-only inset and plays no part in
    // where the FIRST row lands). ───────────────────────────────────────────────────────────────
    await tester.pumpWidget(
      shell(
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ArulTokens.screenPadding,
          ),
          child: RingtoneRow(ringtone: _ringtone, onSet: () {}),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));

    final loadedRow = tester.getRect(find.byType(RingtoneRow));
    final loadedArt = tester.getRect(find.byType(RingtoneTile));
    final loadedTitle = tester.getRect(find.text(_ringtone.title));
    final loadedSubtitle = tester.getRect(find.text(_ringtone.deityLabel!));

    final l10n = AppLocalizations.of(tester.element(find.byType(RingtoneRow)));
    // Play has no text descendant carrying the same label, so bySemanticsLabel resolves to the
    // whole hit box. The Set pill does NOT get this treatment: its label ("Set") duplicates its
    // own Text child, and Flutter's semantics merge leaves the label on the Text's (much smaller)
    // node -> bySemanticsLabel would silently measure the glyphs, not the pill. Same gotcha
    // ringtones_screen_test.dart already works around; find the GestureDetector by its text instead.
    final loadedPlay = tester.getRect(
      find.bySemanticsLabel(l10n.ringtonePreviewSemantic),
    );
    final loadedSet = tester.getRect(
      find.widgetWithText(GestureDetector, l10n.ringtoneSet),
    );

    // ── The row: this is what actually stops the list jumping ───────────────────────────────
    expect(
      skeletonRow.height,
      closeTo(loadedRow.height, 1.0),
      reason: 'row height (RingtoneRow.extentFor on both sides)',
    );

    // ── The art square: a fixed coverSize box on both sides -> full match ────────────────────
    expectFullRect(skeletonArt, loadedArt, 'art');

    // ── Title: origin + line height match; width does not (see file header) ─────────────────
    expectOriginAndHeight(skeletonTitle, loadedTitle, 'title');

    // ── Subtitle: same shape of match, same reason ───────────────────────────────────────────
    expectOriginAndHeight(skeletonSubtitle, loadedSubtitle, 'subtitle');

    // ── Play control: Y + its square hit-box size match on both sides; X does not (header) ────
    expectSizeAndTop(skeletonPlay, loadedPlay, 'play control');

    // The box is the ACCESSIBILITY contract, not just a shared number -> assert the value, so a
    // future edit that shrinks it back below Android's 48 fails here rather than on a phone.
    expect(
      loadedPlay.width,
      closeTo(ArulTokens.minHitTarget, 0.01),
      reason: 'play control: hit box is ArulTokens.minHitTarget wide',
    );
    expect(
      loadedPlay.height,
      closeTo(ArulTokens.minHitTarget, 0.01),
      reason: 'play control: hit box is ArulTokens.minHitTarget tall',
    );

    // ── The gap BETWEEN the two trailing controls — the one piece of horizontal geometry that IS
    // deterministic on both sides (both boxes are fixed-width there, so the Set pill's
    // content-driven width cannot reach it). It is asserted because it is what the hit-target
    // raise actually moved: the boxes went 44 -> 48, so the laid-out gap went 7 -> 5 to keep the
    // DRAWN gap at 12. The skeleton used to write that 7 as a literal; had it stayed one, the
    // placeholder's play button would sit 4px off the real row's and pop sideways on landing —
    // invisible to every other assertion in this file.
    expect(
      skeletonSet.left - skeletonPlay.right,
      closeTo(loadedSet.left - loadedPlay.right, 1.0),
      reason: 'gap between the play control and the Set pill',
    );

    // ── Set pill: Y/height are fixed; the RIGHT edge is flush with the row's own content edge
    // regardless of the pill's own width, because the row's one Expanded (the title column)
    // absorbs all the slack -> the LAST child's trailing edge is deterministic even though its
    // leading edge is not. Left/width are NOT asserted -> see the file header.
    expect(
      skeletonSet.top,
      closeTo(loadedSet.top, 1.0),
      reason: 'Set pill: top edge',
    );
    expect(
      skeletonSet.height,
      closeTo(loadedSet.height, 1.0),
      reason: 'Set pill: height',
    );
    expect(
      skeletonSet.right,
      closeTo(loadedSet.right, 1.0),
      reason:
          'Set pill: right edge (flush with the row regardless of the '
          "pill's own content-driven width)",
    );
  });
}
