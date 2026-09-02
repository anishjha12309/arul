import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      yield _isOnline(await connectivity.checkConnectivity());
    } catch (_) {
      yield true;
    }
    yield* connectivity.onConnectivityChanged.map(_isOnline);
  }

  return statuses().distinct();
});
