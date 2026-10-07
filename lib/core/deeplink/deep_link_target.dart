import 'package:flutter/widgets.dart';

enum ArulTab { wallpapers, ringtones, status }

/// Where a link was delivered from — rides on the target for the GA4-only `deep_link_opened`.
/// Answers which channel actually lands people on content; nothing else reads it.
enum DeepLinkSource {
  appLink,

  installReferrer,

  googleAds,

  meta,

  /// A campaign notification tapped on the phone (`docs/push.md`).
  push,

  debug;

  String get key => switch (this) {
    DeepLinkSource.appLink => 'app_link',
    DeepLinkSource.installReferrer => 'install_referrer',
    DeepLinkSource.googleAds => 'google_ads',
    DeepLinkSource.meta => 'meta',
    DeepLinkSource.push => 'push',
    DeepLinkSource.debug => 'debug',
  };

  static DeepLinkSource fromKey(String? key) => DeepLinkSource.values
      .firstWhere((s) => s.key == key, orElse: () => DeepLinkSource.appLink);
}

/// What a link asked the app to show. One of six shapes:
///   · [WallpaperLinkTarget] — a wallpaper by id; the feed jumps to it on All.
///   · [RingtoneLinkTarget]  — a ringtone by id; the Ringtones tab scrolls it to the top of All.
///   · [StatusLinkTarget]    — a status clip by id; the Status reel jumps to it on All.
///   · [TabLinkTarget]       — just a tab (`screen=ringtones` with no id).
///   · [CategoryLinkTarget]  — the browse feed filtered to one category.
///   · [PremiumLinkTarget]   — the premium screen.
sealed class DeepLinkTarget {
  const DeepLinkTarget({required this.source});

  final DeepLinkSource source;

  ArulTab get tab;

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

/// A status clip by id. With the Status tab flagged off the shell takes it and lands on Wallpapers.
final class StatusLinkTarget extends DeepLinkTarget {
  const StatusLinkTarget(this.id, {super.source = DeepLinkSource.appLink});

  final String id;

  @override
  ArulTab get tab => ArulTab.status;

  @override
  String get kind => 'status';

  @override
  Map<String, Object?> get analyticsProperties => {
    ...super.analyticsProperties,
    'status_id': id,
  };

  @override
  bool operator ==(Object other) =>
      other is StatusLinkTarget && other.id == id && other.source == source;

  @override
  int get hashCode => Object.hash(StatusLinkTarget, id, source);

  @override
  String toString() => 'StatusLinkTarget($id, ${source.key})';
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

/// The browse feed filtered to one category — a campaign push's "Opens: a category".
/// A slug the catalog no longer carries must land on the feed, never on an empty screen or an error.
final class CategoryLinkTarget extends DeepLinkTarget {
  const CategoryLinkTarget(this.slug, {super.source = DeepLinkSource.appLink});

  final String slug;

  @override
  ArulTab get tab => ArulTab.wallpapers;

  @override
  String get kind => 'category';

  @override
  Map<String, Object?> get analyticsProperties => {
    ...super.analyticsProperties,
    'category': slug,
  };

  @override
  bool operator ==(Object other) =>
      other is CategoryLinkTarget &&
      other.slug == slug &&
      other.source == source;

  @override
  int get hashCode => Object.hash(CategoryLinkTarget, slug, source);

  @override
  String toString() => 'CategoryLinkTarget($slug, ${source.key})';
}

/// The premium screen — a campaign push's "Opens: premium screen".
///
/// It is a PUSHED route over the shell, not a dock branch, so it has no tab of its own; [tab] answers
/// Wallpapers only because the sealed contract needs an answer for the shell underneath.
final class PremiumLinkTarget extends DeepLinkTarget {
  const PremiumLinkTarget({super.source = DeepLinkSource.appLink});

  @override
  ArulTab get tab => ArulTab.wallpapers;

  @override
  String get kind => 'premium';

  @override
  bool operator ==(Object other) =>
      other is PremiumLinkTarget && other.source == source;

  @override
  int get hashCode => Object.hash(PremiumLinkTarget, source);

  @override
  String toString() => 'PremiumLinkTarget(${source.key})';
}

class _DeepLinkNotifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// What a link asked the app to open, held until the screen that can show it is ready.
/// Plus the language it asked for, held until the app root can apply it.
/// Written from go_router's `redirect`, which runs before there is an element to read a container from.
/// So a plain STATIC, never a provider — a provider works on a warm link and drops the cold one.
/// The cold one is the case that matters: an ad tap is almost always cold.
class ArulDeepLink {
  const ArulDeepLink._();

  static DeepLinkTarget? _target;
  static String? _lang;
  static bool _landed = false;
  static final _DeepLinkNotifier _notifier = _DeepLinkNotifier();

  /// Shells number themselves as they mount. A link the router delivers hops through `/`, which
  /// rebuilds the shell -> only a shell mounted AFTER it may take it. The outgoing shell's screen
  /// would consume it, be torn down mid-jump, and the user lands on Wallpapers.
  static int _shells = 0;
  static int _firstTakingShell = 0;

  /// Called once per shell mount; its branch screens read the number through [ArulShellScope].
  static int registerShell() => ++_shells;

  /// The router parks a link and heads for `/` -> the shell on screen now must leave it alone.
  static void deferToNextShell() => _firstTakingShell = _shells + 1;

  /// Whether a screen or shell numbered [shell] may peek or take the pending target; null (a push
  /// tap, a test) always may.
  static bool mayTake(int? shell) =>
      shell == null || shell >= _firstTakingShell;

  /// Fires after every [requestTarget]/[requestLocale] — consumers read the pending value themselves.
  static Listenable get changes => _notifier;

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
    _landed = true;
    _notifier.fire();
  }

  /// Record the language a link asked for — validated upstream; the parser only emits shipped codes.
  static void requestLocale(String code) {
    if (code.isEmpty) return;
    _lang = code;
    _notifier.fire();
  }

  /// A link or a campaign tap reached this process — it stays true after the target is consumed.
  /// The review prompt reads it: a person who arrived on something must not land on Play's sheet.
  static bool get landedThisLaunch => _landed;

  /// A campaign tap with no parked target (home, a category, premium) is a landing all the same.
  static void noteExternalOpen() => _landed = true;

  /// The pending target without taking it — the shell peeks to pick a branch, its screen consumes.
  static DeepLinkTarget? get pendingTarget => _target;

  /// Take the pending target if it is a wallpaper, clearing it.
  /// Read-and-clear in ONE call: a target left behind drags the user back on every later rebuild.
  static WallpaperLinkTarget? consumeWallpaper({int? shell}) {
    if (!mayTake(shell)) return null;
    final t = _target;
    if (t is! WallpaperLinkTarget) return null;
    _target = null;
    return t;
  }

  static RingtoneLinkTarget? consumeRingtone({int? shell}) {
    if (!mayTake(shell)) return null;
    final t = _target;
    if (t is! RingtoneLinkTarget) return null;
    _target = null;
    return t;
  }

  static StatusLinkTarget? consumeStatus({int? shell}) {
    if (!mayTake(shell)) return null;
    final t = _target;
    if (t is! StatusLinkTarget) return null;
    _target = null;
    return t;
  }

  static TabLinkTarget? consumeTab({int? shell}) {
    if (!mayTake(shell)) return null;
    final t = _target;
    if (t is! TabLinkTarget) return null;
    _target = null;
    return t;
  }

  static String? consumeLocale() {
    final code = _lang;
    _lang = null;
    return code;
  }

  static void reset() {
    _target = null;
    _lang = null;
    _landed = false;
    _firstTakingShell = 0;
  }
}

/// The number of the shell a branch screen sits in, read when the screen takes a link.
/// Read live, never captured: go_router MOVES the branch screens into the rebuilt shell (one
/// navigation-shell GlobalKey), so a screen built in the outgoing shell ends up in the next one.
class ArulShellScope extends InheritedWidget {
  const ArulShellScope({super.key, required this.shell, required super.child});

  final int shell;

  /// Null outside a shell (a screen pumped alone in a test) -> [ArulDeepLink.mayTake] lets it take.
  static int? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArulShellScope>()?.shell;

  @override
  bool updateShouldNotify(ArulShellScope oldWidget) => oldWidget.shell != shell;
}
