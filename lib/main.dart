import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/providers/shared_preferences_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge. This is already the default at targetSdk 35+ (and the OS
  // enforces it — the immersive modes are now no-ops), but it is stated here so
  // the intent is legible rather than inherited by accident.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

  // Portrait only: every asset in the catalog is 9:16. (Android 16+ ignores this
  // on large screens by policy; phones honour it, which is the whole install base.)
  unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]));

  // A full-screen 1080x1920 wallpaper decodes to ~8.3 MB of RGBA, so Flutter's
  // default 100 MB image cache holds only ~12 of them — enough to thrash, and on
  // a 2 GB device enough to get OOM-killed. Cap it deliberately.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes =
        48 <<
        20 // 48 MB
    ..maximumSize = 60;

  // Resolved before runApp: the wallpaper-apply flow persists its restore flags
  // on the path to a native call that can recreate the Activity, and there is no
  // room there to await a prefs handle.
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const ArulApp(),
    ),
  );
}
