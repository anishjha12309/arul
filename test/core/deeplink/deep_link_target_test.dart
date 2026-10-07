// The parking slot between "a link arrived" and "the screen that can show it is up".
// The shell, the feed, the Ringtones tab and the locale sync all rely on this contract.
// Last write wins, a typed take never eats the other kind, listeners fire on every write, a take clears exactly once.

import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(ArulDeepLink.reset);
  tearDown(ArulDeepLink.reset);

  test('request() is the wallpaper shorthand', () {
    ArulDeepLink.request('w1');
    expect(ArulDeepLink.pendingTarget, const WallpaperLinkTarget('w1'));
    expect(ArulDeepLink.consumeWallpaper()?.id, 'w1');
    expect(ArulDeepLink.pendingTarget, isNull);
  });

  test('an empty id is ignored', () {
    ArulDeepLink.request('');
    expect(ArulDeepLink.pendingTarget, isNull);
  });

  test('last write wins, across kinds', () {
    // A user who taps a ringtone ad after a wallpaper link wants the ringtone -> the two never sit side by side.
    ArulDeepLink.request('w1');
    ArulDeepLink.requestTarget(const RingtoneLinkTarget('r1'));
    expect(ArulDeepLink.pendingTarget, const RingtoneLinkTarget('r1'));
    expect(ArulDeepLink.consumeWallpaper(), isNull);
    expect(ArulDeepLink.consumeRingtone()?.id, 'r1');
  });

  test('a typed take leaves the other kind alone', () {
    // The feed builds before the shell switches tabs -> its wallpaper take must pass a pending ringtone through untouched.
    ArulDeepLink.requestTarget(const RingtoneLinkTarget('r1'));
    expect(ArulDeepLink.consumeWallpaper(), isNull);
    expect(ArulDeepLink.consumeTab(), isNull);
    expect(ArulDeepLink.pendingTarget, const RingtoneLinkTarget('r1'));

    ArulDeepLink.requestTarget(const TabLinkTarget(ArulTab.ringtones));
    expect(ArulDeepLink.consumeRingtone(), isNull);
    expect(ArulDeepLink.consumeTab()?.tab, ArulTab.ringtones);
    expect(ArulDeepLink.pendingTarget, isNull);
  });

  test('a take clears — the same target never opens twice', () {
    ArulDeepLink.request('w1');
    expect(ArulDeepLink.consumeWallpaper(), isNotNull);
    expect(ArulDeepLink.consumeWallpaper(), isNull);
  });

  test('the language is held and taken independently of the target', () {
    ArulDeepLink.requestLocale('hi');
    ArulDeepLink.request('w1');
    expect(ArulDeepLink.consumeLocale(), 'hi');
    expect(ArulDeepLink.consumeLocale(), isNull);
    expect(ArulDeepLink.pendingTarget, const WallpaperLinkTarget('w1'));
  });

  test('changes fires on every write, target or language', () {
    var fired = 0;
    void listener() => fired++;
    ArulDeepLink.changes.addListener(listener);
    addTearDown(() => ArulDeepLink.changes.removeListener(listener));

    ArulDeepLink.request('w1');
    ArulDeepLink.requestLocale('ta');
    ArulDeepLink.requestTarget(const TabLinkTarget(ArulTab.wallpapers));
    expect(fired, 3);

    // A take is silent: consumers are reacting to arrivals, not departures.
    ArulDeepLink.consumeTab();
    ArulDeepLink.consumeLocale();
    expect(fired, 3);
  });

  test('each target knows its tab, kind and analytics shape', () {
    const w = WallpaperLinkTarget('w1', source: DeepLinkSource.meta);
    const r = RingtoneLinkTarget('r1', source: DeepLinkSource.googleAds);
    const t = TabLinkTarget(ArulTab.ringtones);
    expect(w.tab, ArulTab.wallpapers);
    expect(r.tab, ArulTab.ringtones);
    expect(t.tab, ArulTab.ringtones);
    expect(w.analyticsProperties, {
      'kind': 'wallpaper',
      'source': 'meta',
      'wallpaper_id': 'w1',
    });
    expect(r.analyticsProperties, {
      'kind': 'ringtone',
      'source': 'google_ads',
      'ringtone_id': 'r1',
    });
    expect(t.analyticsProperties, {
      'kind': 'tab',
      'source': 'app_link',
      'tab': 'ringtones',
    });
  });

  test('a link the router parks on its way through `/` is left for the '
      'shell that mounts after it — the one on screen is torn down', () {
    final onScreen = ArulDeepLink.registerShell();
    ArulDeepLink.deferToNextShell();
    ArulDeepLink.requestTarget(const StatusLinkTarget('s1'));

    expect(ArulDeepLink.mayTake(onScreen), isFalse);
    expect(ArulDeepLink.consumeStatus(shell: onScreen), isNull);
    expect(ArulDeepLink.pendingTarget, const StatusLinkTarget('s1'));

    final next = ArulDeepLink.registerShell();
    expect(ArulDeepLink.consumeStatus(shell: next)?.id, 's1');
  });

  test('a target from anywhere else (a push tap, a deferred link) is taken '
      'by the shell already on screen', () {
    final onScreen = ArulDeepLink.registerShell();
    ArulDeepLink.requestTarget(const WallpaperLinkTarget('w1'));
    expect(ArulDeepLink.consumeWallpaper(shell: onScreen)?.id, 'w1');
  });

  test('DeepLinkSource round-trips its persisted key', () {
    for (final source in DeepLinkSource.values) {
      expect(DeepLinkSource.fromKey(source.key), source);
    }
    expect(
      DeepLinkSource.fromKey(null),
      DeepLinkSource.appLink,
      reason: 'a pref written before the key existed still resolves',
    );
  });
}
