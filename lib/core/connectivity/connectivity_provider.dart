import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../perf/boot_trace.dart';

/// The [Connectivity] instance -> connectivity_plus has no platform channel under `flutter test` ->
/// behind a provider so tests can inject a fake.
final connectivityProvider = Provider<Connectivity>((_) => Connectivity());

/// Maps a connectivity snapshot to a plain online/offline bool.
///
/// Online = ANY usable transport (wifi, mobile, ethernet, vpn, bluetooth, other, satellite);
/// offline = the list is `[none]` or empty.
/// Transport-level BY DESIGN, never a reachability probe -> the product wants the offline state the
/// instant the network drops -> a round-trip probe would be slower and could itself hang.
bool _isOnline(List<ConnectivityResult> results) =>
    results.any((r) => r != ConnectivityResult.none);

/// The launch's first transport reading, asked at the top of `main()`; [isOnlineProvider] seeds from it.
// The splash decides whether to hold the sign-in sheet ~200 ms into the process, and a reading first
// asked there is still unanswered on a cold budget phone — so the sheet would fire offline and fail.
abstract final class LaunchLinkProbe {
  static Future<List<ConnectivityResult>>? _first;

  static void start() {
    final first = Connectivity().checkConnectivity();
    _first = first;
    first.then(
      (r) =>
          BootTrace.mark('link probe: ${_isOnline(r) ? 'online' : 'OFFLINE'}'),
      onError: (Object _) {},
    );
  }

  /// Handed to the provider's first reading once; null in tests and when `main()` never asked.
  static Future<List<ConnectivityResult>>? take() {
    final first = _first;
    _first = null;
    return first;
  }
}

/// `true` while the device is online, `false` the moment it drops to `none`.
///
/// Seeds from [Connectivity.checkConnectivity] -> the first frame after launch already knows ->
/// then follows [Connectivity.onConnectivityChanged].
/// The platform stream can repeat itself -> `distinct()` collapses the duplicates.
/// A loading snapshot or a failed first check must read as ONLINE -> the gate fires only on a KNOWN
/// offline result -> a slow first probe never flashes the offline screen over a live network.
final isOnlineProvider = StreamProvider<bool>((ref) {
  final connectivity = ref.watch(connectivityProvider);

  Stream<bool> statuses() async* {
    try {
      yield _isOnline(
        await (LaunchLinkProbe.take() ?? connectivity.checkConnectivity()),
      );
    } catch (_) {
      yield true;
    }
    yield* connectivity.onConnectivityChanged.map(_isOnline);
  }

  return statuses().distinct();
});
