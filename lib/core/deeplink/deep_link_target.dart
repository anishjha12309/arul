/// The wallpaper a link asked the app to open, held until the feed can show it.
///
/// Two very different paths write here, and the feed must not care which:
///   · **App Link** — the app was already installed, Android matched
///     `https://arul.hsrutility.com/w/<id>` against assetlinks.json and handed
///     the route straight to go_router, which writes it here on its way to `/`.
///   · **Deferred (install referrer)** — the app was NOT installed. The tap went
///     to Play via the Worker's `/w/:id` redirect, and Play replayed `w=<id>` to
///     `InstallReferrerService` on first launch, which seeds it here.
///
/// Deliberately a plain static rather than a provider. It is written from
/// go_router's `redirect`, which runs during the FIRST router evaluation on a
/// cold start — before there is a reliable element to read a `ProviderContainer`
/// from — so a provider here would work on a warm link and silently drop the
/// cold one, which is the case that matters (an ad tap is almost always cold).
/// The feed already reads its apply-restore flags imperatively for the same
/// reason; this follows that.
class ArulDeepLink {
  const ArulDeepLink._();

  static String? _wallpaperId;

  /// Record the wallpaper a link asked for. Last write wins: a user who taps a
  /// second link before the feed has drained the first wants the second one.
  static void request(String wallpaperId) {
    if (wallpaperId.isEmpty) return;
    _wallpaperId = wallpaperId;
  }

  /// Take the pending id, clearing it.
  ///
  /// Read-and-clear in one call on purpose: the feed consumes this on the first
  /// catalog it sees, and a target left behind would drag the user back to the
  /// same wallpaper on every later rebuild of that list.
  static String? consume() {
    final id = _wallpaperId;
    _wallpaperId = null;
    return id;
  }

  /// Test seam — clears state between tests.
  static void reset() => _wallpaperId = null;
}
