import 'package:flutter/foundation.dart';

/// Which of the shell's browse tabs a link points into.
enum ArulTab { wallpapers, ringtones }

/// Where a link was delivered from — rides on the target for the GA4-only `deep_link_opened`.
/// Answers which channel actually lands people on content; nothing else reads it.
enum DeepLinkSource {
  /// Android handed the app an intent — a verified https App Link, or Meta's `fb<APP_ID>://open`.
  appLink,

  /// Play Install Referrer replayed the Worker's redirect payload on the first launch after install.
  installReferrer,

  /// Google Ads App Campaign deferred deep link, fetched by GA4F.
  googleAds,

  /// Meta deferred deep link (`AppLinkData.fetchDeferredAppLinkData`).
  meta,

  /// The `DEBUG_INSTALL_REFERRER` / `DEBUG_DEFERRED_LINK` test seams.
  debug;

  /// Wire form for analytics and the persisted pending target.
  String get key => switch (this) {
    DeepLinkSource.appLink => 'app_link',
    DeepLinkSource.installReferrer => 'install_referrer',
    DeepLinkSource.googleAds => 'google_ads',
    DeepLinkSource.meta => 'meta',
    DeepLinkSource.debug => 'debug',
  };

  static DeepLinkSource fromKey(String? key) => DeepLinkSource.values
      .firstWhere((s) => s.key == key, orElse: () => DeepLinkSource.appLink);
}

/// What a link asked the app to show. One of three shapes:
///   · [WallpaperLinkTarget] — a wallpaper by id; the feed jumps to it on All.
///   · [RingtoneLinkTarget]  — a ringtone by id; the Ringtones tab scrolls it to the top of All.
///   · [TabLinkTarget]       — just a tab (`screen=ringtones` with no id).
sealed class DeepLinkTarget {
  const DeepLinkTarget({required this.source});

  final DeepLinkSource source;

  /// The tab the shell must be on for this target to be visible.
  ArulTab get tab;

  /// `kind` for analytics.
  String get kind;

  /// Analytics for `deep_link_opened` — GA4-only, deliberately off the PostHog list and Meta's ★ set.
  Map<String, Object?> get analyticsProperties => {
    'kind': kind,
    'source': source.key,
  };
}

final class WallpaperLinkTarget extends DeepLinkTarget {
  const WallpaperLinkTarget(this.id, {super.source = DeepLinkSource.appLink});

  final String id;

  @override
  ArulTab get tab => ArulTab.wallpapers;

  @override
  String get kind => 'wallpaper';

  @override
  Map<String, Object?> get analyticsProperties => {
    ...super.analyticsProperties,
    'wallpaper_id': id,
  };

  @override
  bool operator ==(Object other) =>
      other is WallpaperLinkTarget && other.id == id && other.source == source;

  @override
  int get hashCode => Object.hash(WallpaperLinkTarget, id, source);

  @override
  String toString() => 'WallpaperLinkTarget($id, ${source.key})';
}

final class RingtoneLinkTarget extends DeepLinkTarget {
  const RingtoneLinkTarget(this.id, {super.source = DeepLinkSource.appLink});

  final String id;

  @override
  ArulTab get tab => ArulTab.ringtones;

  @override
  String get kind => 'ringtone';

  @override
  Map<String, Object?> get analyticsProperties => {
    ...super.analyticsProperties,
    'ringtone_id': id,
  };

  @override
  bool operator ==(Object other) =>
      other is RingtoneLinkTarget && other.id == id && other.source == source;

  @override
  int get hashCode => Object.hash(RingtoneLinkTarget, id, source);

  @override
  String toString() => 'RingtoneLinkTarget($id, ${source.key})';
}

final class TabLinkTarget extends DeepLinkTarget {
  const TabLinkTarget(this.tab, {super.source = DeepLinkSource.appLink});

  @override
  final ArulTab tab;

  @override
  String get kind => 'tab';

  @override
  Map<String, Object?> get analyticsProperties => {
    ...super.analyticsProperties,
    'tab': tab.name,
  };

  @override
  bool operator ==(Object other) =>
      other is TabLinkTarget && other.tab == tab && other.source == source;

  @override
  int get hashCode => Object.hash(TabLinkTarget, tab, source);

  @override
  String toString() => 'TabLinkTarget(${tab.name}, ${source.key})';
}

class _DeepLinkNotifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// What a link asked the app to open, held until the screen that can show it is ready.
/// Plus the language it asked for, held until the app root can apply it.
///
/// Five paths write here, and consumers must not care which:
///   · **App Link / Meta scheme** — installed already; go_router's top-level redirect parks it here;
///   · **Play Install Referrer** — NOT installed; Play replays the Worker's payload on first launch;
///   · **Google Ads DDL** and **Meta deferred** — fetched by GA4F / the Meta SDK after an ad install;
///   · the debug test seams.
///
/// Written from go_router's `redirect`, which runs before there is an element to read a container from.
/// So a plain STATIC, never a provider — a provider works on a warm link and drops the cold one.
/// The cold one is the case that matters: an ad tap is almost always cold.
/// [changes] fires on every write -> a screen already up can react to a target that lands late.
/// GA4F and Meta deliver mid-startup, and an App Link can arrive while the app is warm.
class ArulDeepLink {
  const ArulDeepLink._();

  static DeepLinkTarget? _target;
  static String? _lang;
  static final _DeepLinkNotifier _notifier = _DeepLinkNotifier();

  /// Fires after every [requestTarget]/[requestLocale] — consumers read the pending value themselves.
  static Listenable get changes => _notifier;

  /// Record the wallpaper a link asked for.
  ///
  /// The wallpaper-only entry point the referrer path and the tests use — see [requestTarget].
  static void request(
    String wallpaperId, {
    DeepLinkSource source = DeepLinkSource.appLink,
  }) {
    if (wallpaperId.isEmpty) return;
    requestTarget(WallpaperLinkTarget(wallpaperId, source: source));
  }

  /// Record what a link asked for. LAST WRITE WINS — a second tap before the first showed wants that.
  /// A ringtone link replaces a pending wallpaper, never sits beside it.
  static void requestTarget(DeepLinkTarget target) {
    _target = target;
    _notifier.fire();
  }

  /// Record the language a link asked for — validated upstream; the parser only emits shipped codes.
  static void requestLocale(String code) {
    if (code.isEmpty) return;
    _lang = code;
    _notifier.fire();
  }

  /// The pending target without taking it — the shell peeks to pick a branch, its screen consumes.
  static DeepLinkTarget? get pendingTarget => _target;

  /// Take the pending target if it is a wallpaper, clearing it.
  ///
  /// The feed builds before the shell switched tabs -> a wallpaper take must never eat a ringtone.
  /// Read-and-clear in ONE call: a target left behind drags the user back on every later rebuild.
  static WallpaperLinkTarget? consumeWallpaper() {
    final t = _target;
    if (t is! WallpaperLinkTarget) return null;
    _target = null;
    return t;
  }

  /// Take the pending target if it is a ringtone, clearing it.
  static RingtoneLinkTarget? consumeRingtone() {
    final t = _target;
    if (t is! RingtoneLinkTarget) return null;
    _target = null;
    return t;
  }

  /// Take the pending target if it only names a tab, clearing it.
  static TabLinkTarget? consumeTab() {
    final t = _target;
    if (t is! TabLinkTarget) return null;
    _target = null;
    return t;
  }

  /// Take the pending language, clearing it.
  static String? consumeLocale() {
    final code = _lang;
    _lang = null;
    return code;
  }

  /// Test seam — clears state between tests; listeners are the widgets' own to remove.
  static void reset() {
    _target = null;
    _lang = null;
  }
}
