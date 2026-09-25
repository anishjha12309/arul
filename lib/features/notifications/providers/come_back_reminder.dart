import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../core/config/build_info.dart';
import '../../../core/experiments/experiments.dart';
import '../../../core/providers/geo_language_service.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../core/providers/shared_preferences_provider.dart';
import '../../auth/domain/auth_service.dart';
import '../../auth/domain/regional_art.dart';
import '../data/notification_service.dart';
import 'notification_providers.dart';

part 'come_back_reminder.g.dart';

/// The sign-in factorial's B3 arm (`exp_reminder`): ONE local post about an hour after the install's
/// FIRST Google surface, for the person who left with it up and never came back.
///
/// Android 12 and below only — 13+ needs a permission the wall must never ask for. Armed once per
/// install, disarmed by anything that shows the person came back: an attempt settling, a resume,
/// or a cold start (docs/notifications.md).
class ComeBackReminder {
  ComeBackReminder({
    required this._prefs,
    required this._notifications,
    required this._active,
    required this._sdkInt,
    required this._copy,
    required this._picture,
    DateTime Function()? now,
    this.delay = const Duration(minutes: 60),
  }) : _now = now ?? DateTime.now;

  final SharedPreferences _prefs;
  final NotificationService _notifications;
  final bool _active;
  final Future<int?> Function() _sdkInt;
  final ({String title, String body}) Function() _copy;
  final Future<String?> Function() _picture;
  final DateTime Function() _now;
  final Duration delay;

  /// Bumped by every [disarm] -> an arm still awaiting the plugin when the person came back cancels
  /// what it just scheduled instead of leaving it armed.
  var _epoch = 0;

  /// Set the moment the first surface is seen -> "once per install" survives a failed schedule.
  static const usedKey = 'arul_come_back_used';

  /// The armed post's due instant (epoch ms), present only while one may still be pending.
  static const dueKey = 'arul_come_back_due';

  /// Android 12L — the last release that posts without `POST_NOTIFICATIONS`.
  static const maxSdk = 32;

  /// A cold start means the person is back (or tapped the post) -> nothing left to remind them of.
  /// A killed arm drops what the previous launch armed.
  Future<void> coldStart() async {
    if (_prefs.getInt(dueKey) != null) await disarm();
  }

  Future<void> onSurfaceShown() async {
    if (!_active || (_prefs.getBool(usedKey) ?? false)) return;
    await _prefs.setBool(usedKey, true);
    final epoch = _epoch;
    final sdk = await _sdkInt();
    if (sdk == null || sdk > maxSdk) return;
    // The picture first: it waits for the region, and the regional arm's language settles with it.
    final picture = await _picture();
    final due = _now().add(delay);
    final copy = _copy();
    final armed = await _notifications.scheduleComeBack(
      due: due,
      title: copy.title,
      body: copy.body,
      picturePath: picture,
    );
    if (!armed) return;
    if (epoch != _epoch) {
      await _notifications.cancelComeBack();
      return;
    }
    await _prefs.setInt(dueKey, due.millisecondsSinceEpoch);
  }

  Future<void> disarm() async {
    _epoch++;
    if (_prefs.getInt(dueKey) == null) return;
    await _prefs.remove(dueKey);
    try {
      await _notifications.cancelComeBack();
    } on PlatformException catch (e) {
      debugPrint('[ComeBack] cancel failed: $e');
    }
  }
}

/// Started from the splash, before the splash's own sign-in attempt can bring Google's surface up.
@Riverpod(keepAlive: true)
ComeBackReminder comeBackReminder(Ref ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  // QA seam, sideloads only: `QA_COME_BACK_DELAY_S=60` posts after a minute on ANY Android (grant
  // POST_NOTIFICATIONS by adb on 13+), so the post itself is checkable on a modern test phone.
  const qaDelay = int.fromEnvironment('QA_COME_BACK_DELAY_S');
  final qa = qaDelay > 0 && !PlayInstall.isPlay;
  final reminder = ComeBackReminder(
    prefs: prefs,
    notifications: ref.read(notificationServiceProvider),
    active: ref.read(experimentsProvider).reminderActive,
    sdkInt: qa
        ? () async => ComeBackReminder.maxSdk
        : () => AndroidVersion.sdkInt,
    delay: qa ? const Duration(seconds: qaDelay) : const Duration(minutes: 60),
    copy: () {
      final l10n = lookupAppLocalizations(ref.read(localeProvider));
      return (title: l10n.comeBackTitle, body: l10n.comeBackBody);
    },
    // The same poster the regional arm would show for this region, whichever B2 arm this is -> the
    // two flips stay independent.
    // The first surface lands before `/geo` answers -> wait for it, bounded like the ask itself.
    picture: () async {
      await ref
          .read(geoLanguageServiceProvider)
          .settled
          .timeout(const Duration(seconds: 15), onTimeout: () {});
      return _posterFile(
        regionalPosterFor(prefs.getString(geoRegionPrefsKey)),
      );
    },
  );
  unawaited(reminder.coldStart());
  final signals = SignInPhase.signals.stream.listen((signal) {
    switch (signal) {
      case SignInSignal.surfaceShown:
        unawaited(reminder.onSurfaceShown());
      case SignInSignal.settled:
        unawaited(reminder.disarm());
    }
  });
  final lifecycle = AppLifecycleListener(
    onResume: () => unawaited(reminder.disarm()),
  );
  ref.onDispose(() {
    unawaited(signals.cancel());
    lifecycle.dispose();
  });
  return reminder;
}

/// The plugin reads a big picture from a FILE path when it posts, possibly from its boot receiver
/// with no Flutter alive -> the poster's 2:1 band around the face is written out once.
Future<String?> _posterFile(RegionalPoster poster) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final name = poster.asset.split('/').last.replaceAll('.webp', '');
    final file = File('${dir.path}/come_back_$name.png');
    if (!await file.exists()) {
      final data = await rootBundle.load(poster.asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final image = (await codec.getNextFrame()).image;
      final w = image.width.toDouble();
      final h = w / 2;
      final top = (poster.faceY * image.height - h * 0.35).clamp(
        0.0,
        image.height - h,
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        Rect.fromLTWH(0, top, w, h),
        Rect.fromLTWH(0, 0, w, h),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final band = await recorder.endRecording().toImage(w.toInt(), h.toInt());
      final png = await band.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      band.dispose();
      if (png == null) return null;
      await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
    }
    return file.path;
  } catch (e) {
    debugPrint('[ComeBack] poster copy failed: $e');
    return null;
  }
}
