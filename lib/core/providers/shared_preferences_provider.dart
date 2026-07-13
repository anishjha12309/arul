import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Synchronous [SharedPreferences], overridden in `main()` after an await.
///
/// It is a hard override rather than a FutureProvider because the apply flow
/// writes its pending-restore flags on the path to a native call that can
/// recreate the Activity — there is no room there to await a prefs handle.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw StateError('sharedPreferencesProvider must be overridden in main()');
});
