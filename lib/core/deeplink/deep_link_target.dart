import 'package:flutter/foundation.dart';

/// Which of the shell's browse tabs a link points into.
enum ArulTab { wallpapers, ringtones }

/// Where a link was delivered from. Rides on the target for the GA4-only
/// `deep_link_opened` event, so "which channel actually lands people on the
/// content" is answerable — nothing else reads it.
enum DeepLinkSource {
  /// Android handed the app an intent: a verified https App Link, or the
  /// `fb<APP_ID>://open` scheme Meta's apps use.
  appLink,

  /// Play Install Referrer replayed the Worker's `/w/`+`/r/` redirect payload
  /// on the first launch after a store install.
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
///   · [RingtoneLinkTarget]  — a ringtone by id; the Ringtones tab scrolls it to
///     the top of All.
///   · [TabLinkTarget]       — just a tab (`screen=ringtones` with no id).
sealed class DeepLinkTarget {
  const DeepLinkTarget({required this.source});

  final DeepLinkSource source;

  /// The tab the shell must be on for this target to be visible.
  ArulTab get tab;

  /// `kind` for analytics.
  String get kind;

  /// Analytics properties for `deep_link_opened`. GA4-only — the event is
  /// deliberately absent from the PostHog allow-list and from Meta's ★ set.
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

/// What a link asked the app to open, held until the screen that can show it
/// is ready — plus the language it asked for, held until the app root can
/// apply it.
///
/// Five very different paths write here, and the consumers must not care which:
///   · **App Link / Meta scheme** — the app was installed; Android handed the
///     intent's URI to go_router, whose top-level redirect parks it here on
///     its way to `/`.
///   · **Play Install Referrer** — the app was NOT installed; the Worker's
///     `/w/:id` or `/r/:id` redirect sent the tap to Play, which replays the
///     payload to `InstallReferrerService` on first launch.
///   · **Google Ads DDL** and **Meta deferred** — fetched over the network by
///     GA4F / the Meta SDK after an ad install, bridged from `MainActivity`
///     through `DeferredLinkService`.
///   · the debug test seams.
///
/// Deliberately a plain static rather than a provider. It is written from
/// go_router's `redirect`, which runs during the FIRST router evaluation on a
/// cold start — before there is a reliable element to read a `ProviderContainer`
/// from — so a provider here would work on a warm link and silently drop the
/// cold one, which is the case that matters (an ad tap is almost always cold).
///
/// [changes] fires on every write so a screen that is already up (the feed
/// behind the Ringtones tab, the shell deciding which branch to show, the root
/// applying a language) can react to a target that lands late — GA4F and Meta
/// deliver mid-startup, and an App Link can arrive while the app is warm.
class ArulDeepLink {
  const ArulDeepLink._();

  static DeepLinkTarget? _target;
  static String? _lang;
  static final _DeepLinkNotifier _notifier = _DeepLinkNotifier();

  /// Fires after every [requestTarget] / [requestLocale]. Consumers read the
  /// pending value themselves; nothing is passed.
  static Listenable get changes => _notifier;

  /// Record the wallpaper a link asked for.
  ///
  /// Kept as the wallpaper-only entry point the referrer path and the tests
  /// already use; see [requestTarget] for the general form.
  static void request(
    String wallpaperId, {
    DeepLinkSource source = DeepLinkSource.appLink,
  }) {
    if (wallpaperId.isEmpty) return;
    requestTarget(WallpaperLinkTarget(wallpaperId, source: source));
  }

  /// Record what a link asked for. Last write wins: a user who taps a second
  /// link before the first was shown wants the second one — and a ringtone
  /// link replaces a pending wallpaper, never sits beside it.
  static void requestTarget(DeepLinkTarget target) {
    _target = target;
    _notifier.fire();
  }

  /// Record the language a link asked for. Validated upstream (the parser
  /// only emits codes from `supportedAppLocales`).
  static void requestLocale(String code) {
    if (code.isEmpty) return;
    _lang = code;
    _notifier.fire();
  }

  /// The pending target without taking it — the shell peeks to decide which
  /// branch to show, and leaves the consume to that branch's screen.
  static DeepLinkTarget? get pendingTarget => _target;

  /// Take the pending target if it is a wallpaper, clearing it. A pending
  /// ringtone is left alone: the feed builds before the shell has switched
  /// tabs, and a wallpaper-typed take must never eat a ringtone link.
  ///
  /// Read-and-clear in one call on purpose: the feed consumes this on the
  /// first catalog it sees, and a target left behind would drag the user back
  /// to the same wallpaper on every later rebuild of that list.
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

  /// Test seam — clears state between tests (listeners are the widgets' own
  /// to remove).
  static void reset() {
    _target = null;
    _lang = null;
  }
}
