import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Synchronous [SharedPreferences], overridden in `main()` after an await.
///
/// The apply flow writes pending-restore flags on the way to a call that can recreate the Activity.
/// There is no room there to await a prefs handle -> a hard override, never a FutureProvider.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw StateError('sharedPreferencesProvider must be overridden in main()');
});
