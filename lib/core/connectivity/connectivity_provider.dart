import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The [Connectivity] instance, behind a provider so tests can inject a fake
/// (connectivity_plus has no platform channel under `flutter test`).
final connectivityProvider = Provider<Connectivity>((_) => Connectivity());

/// Maps a connectivity snapshot to a plain online/offline bool.
///
/// Online = the device reports ANY usable transport (wifi / mobile / ethernet /
/// vpn / bluetooth / other / satellite). Offline = the list is `[none]` (or
/// empty). This is deliberately transport-level, not a reachability probe: the
/// product decision is "the instant the network drops, show the offline state",
/// which a fast, robust interface check delivers — a full round-trip probe would
/// be slower and could itself hang.
bool _isOnline(List<ConnectivityResult> results) =>
    results.any((r) => r != ConnectivityResult.none);

/// `true` while the device is online, `false` the moment it drops to `none`.
///
/// Seeds from an initial [Connectivity.checkConnectivity] so the first frame
/// after launch already knows online/offline, then follows
/// [Connectivity.onConnectivityChanged]. `distinct()` collapses the duplicate
/// emissions the platform stream can produce.
///
/// While this is still resolving its very first value (a loading snapshot) or
/// if the initial check fails, callers should treat the app as ONLINE and keep
/// the normal path — the offline gate fires only on a *known* offline result,
/// so a slow first probe never flashes the offline screen over a live network.
final isOnlineProvider = StreamProvider<bool>((ref) {
  final connectivity = ref.watch(connectivityProvider);

  Stream<bool> statuses() async* {
    // Seed with the current state so the gate is correct on the first frame.
    // A failing probe is treated as online (don't bounce a working feed).
    try {
      yield _isOnline(await connectivity.checkConnectivity());
    } catch (_) {
      yield true;
    }
    yield* connectivity.onConnectivityChanged.map(_isOnline);
  }

  return statuses().distinct();
});
