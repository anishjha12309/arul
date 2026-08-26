// Unit tests for InstallReferrerService — the pure parsing of a Play Install
// Referrer payload into our referral code and deep-link request, the links it
// builds, and the persisted handoff. No platform channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arul/core/deeplink/deep_link_parser.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/features/referral/data/install_referrer_service.dart';

void main() {
  group('InstallReferrerService.parseReferralCode', () {
    test('extracts ref= from our own share payload', () {
      expect(
        InstallReferrerService.parseReferralCode('ref=ABCD1234'),
        'ABCD1234',
      );
    });

    test('finds ref among utm params Play may append', () {
      expect(
        InstallReferrerService.parseReferralCode(
          'utm_source=whatsapp&ref=abcd1234&utm_medium=social',
        ),
        'ABCD1234', // normalized to uppercase
      );
    });

    test('accepts a bare code with no query syntax', () {
      expect(InstallReferrerService.parseReferralCode('WXYZ7890'), 'WXYZ7890');
    });

    test('returns null for empty / null / organic (no code)', () {
      expect(InstallReferrerService.parseReferralCode(null), isNull);
      expect(InstallReferrerService.parseReferralCode(''), isNull);
      expect(InstallReferrerService.parseReferralCode('   '), isNull);
      expect(
        InstallReferrerService.parseReferralCode('utm_source=google-play'),
        isNull,
      );
    });

    test('rejects junk that is not a plausible code', () {
      // Contains query syntax but no known key.
      expect(
        InstallReferrerService.parseReferralCode('foo=bar&baz=qux'),
        isNull,
      );
      // Too long / has illegal chars as a bare value.
      expect(
        InstallReferrerService.parseReferralCode('this-is-not-a-code!!'),
        isNull,
      );
    });

    test('buildShareLink embeds the code as an encoded referrer payload', () {
      final link = InstallReferrerService.buildShareLink('ABCD1234');
      expect(link, contains('id=com.hsrutility.arul'));
      // "ref=ABCD1234" URL-encoded → "ref%3DABCD1234".
      expect(link, contains('referrer=ref%3DABCD1234'));
      // Round-trips back to the same code.
      final referrer = Uri.parse(link).queryParameters['referrer'];
      expect(InstallReferrerService.parseReferralCode(referrer), 'ABCD1234');
    });
  });

  // The deferred half of the deep link: an ad/share tap by someone WITHOUT the
  // app. The Worker's /w/:id or /r/:id sends them to Play with
  // `ref=<code>&w=<id>&lang=<code>` (or `r=<id>`), Play replays it on first
  // launch, and these turn it back into what to open and in which language.
  group('InstallReferrerService referrer payload parsing', () {
    const id = '95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f';
    const rid = '0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d';

    test('extracts w= from the payload the Worker builds', () {
      expect(
        InstallReferrerService.parseWallpaperTarget('ref=ABCD1234&w=$id'),
        id,
      );
    });

    test('extracts r= from the ringtone payload', () {
      expect(
        InstallReferrerService.parseRingtoneTarget('ref=ABCD1234&r=$rid'),
        rid,
      );
      expect(InstallReferrerService.parseWallpaperTarget('r=$rid'), isNull);
    });

    test('extracts lang= and reduces it to a shipped code', () {
      expect(InstallReferrerService.parseLang('w=$id&lang=hi'), 'hi');
      expect(InstallReferrerService.parseLang('lang=TA-IN'), 'ta');
      expect(InstallReferrerService.parseLang('w=$id&lang=fr'), isNull);
    });

    test('finds w among utm params Play may append', () {
      expect(
        InstallReferrerService.parseWallpaperTarget(
          'utm_source=fb&w=$id&utm_medium=cpc',
        ),
        id,
      );
    });

    test('is independent of the referral code — either half can be absent', () {
      // An ad click carries no referral code; a plain Refer & Earn share carries
      // no wallpaper. Neither may discard the other.
      expect(InstallReferrerService.parseWallpaperTarget('w=$id'), id);
      expect(InstallReferrerService.parseReferralCode('w=$id'), isNull);
      expect(
        InstallReferrerService.parseWallpaperTarget('ref=ABCD1234'),
        isNull,
      );
      expect(
        InstallReferrerService.parseReferralCode('ref=ABCD1234'),
        'ABCD1234',
      );
    });

    test('rejects anything that is not a uuid', () {
      // This string comes from outside the app and is about to select a row.
      for (final raw in [
        null,
        '',
        'w=',
        'w=not-a-uuid',
        'w=../../etc/passwd',
        'organic',
        'utm_source=google-play&utm_medium=organic',
      ]) {
        expect(
          InstallReferrerService.parseWallpaperTarget(raw),
          isNull,
          reason: 'must not accept "$raw"',
        );
      }
    });

    test('buildWallpaperLink is an App Link on the verified host', () {
      final link = InstallReferrerService.buildWallpaperLink(
        id,
        code: 'ABCD1234',
      );
      // https on OUR host is what lets Android intercept it for an installed
      // user; a Play URL or an arul:// scheme cannot do that from an ad.
      expect(link, 'https://$kDeepLinkHost/w/$id?ref=ABCD1234');
    });

    test('buildWallpaperLink still deep-links when there is no code', () {
      // Losing attribution must never also cost the deep link — that is the half
      // that converts.
      expect(
        InstallReferrerService.buildWallpaperLink(id),
        'https://$kDeepLinkHost/w/$id',
      );
    });

    test(
      'the ad-creative forms carry lang, and round-trip through the parser',
      () {
        final w = InstallReferrerService.buildWallpaperLink(id, lang: 'hi');
        final r = InstallReferrerService.buildRingtoneLink(
          rid,
          code: 'ABCD1234',
          lang: 'ta',
        );
        expect(w, 'https://$kDeepLinkHost/w/$id?lang=hi');
        expect(r, 'https://$kDeepLinkHost/r/$rid?ref=ABCD1234&lang=ta');

        final parsedW = parseDeepLink(w, source: DeepLinkSource.appLink);
        expect(parsedW?.target, const WallpaperLinkTarget(id));
        expect(parsedW?.lang, 'hi');
        final parsedR = parseDeepLink(r, source: DeepLinkSource.appLink);
        expect(parsedR?.target, const RingtoneLinkTarget(rid));
        expect(parsedR?.lang, 'ta');
      },
    );

    test('the host matches the one the app builds links for', () {
      // Four places must agree or verification fails silently and every link
      // opens a browser: this constant, AndroidManifest's android:host, the
      // wrangler.toml custom domain, and whoever serves assetlinks.json.
      expect(kDeepLinkHost, 'arul.hsrutility.com');
    });
  });

  // The durable handoff: whatever path delivered it, a target and a language
  // are persisted (to survive the startup race and a process death) AND handed
  // to the live app, and the two kinds never sit in prefs together.
  group('InstallReferrerService queue + pending', () {
    const id = '95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f';
    const rid = '0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d';

    setUp(ArulDeepLink.reset);
    tearDown(ArulDeepLink.reset);

    Future<InstallReferrerService> service([
      Map<String, Object> initial = const {},
    ]) async {
      SharedPreferences.setMockInitialValues(initial);
      return InstallReferrerService(await SharedPreferences.getInstance());
    }

    test('queueRequest persists both halves and seeds the live slot', () async {
      final s = await service();
      await s.queueRequest(
        DeepLinkRequest(
          target: const WallpaperLinkTarget(
            id,
            source: DeepLinkSource.googleAds,
          ),
          lang: 'hi',
        ),
      );
      expect(s.pendingWallpaperId, id);
      expect(s.pendingLang, 'hi');
      expect(
        s.pendingTarget,
        const WallpaperLinkTarget(id, source: DeepLinkSource.googleAds),
        reason: 'the source survives a process death too',
      );
      expect(ArulDeepLink.pendingTarget, s.pendingTarget);
      expect(ArulDeepLink.consumeLocale(), 'hi');
    });

    test('a ringtone replaces a pending wallpaper (last write wins)', () async {
      final s = await service();
      await s.queueTarget(const WallpaperLinkTarget(id));
      await s.queueTarget(const RingtoneLinkTarget(rid));
      expect(s.pendingWallpaperId, isNull);
      expect(s.pendingRingtoneId, rid);
      expect(s.pendingTarget, const RingtoneLinkTarget(rid));
    });

    test('a tab-only target is handed live but never persisted', () async {
      final s = await service();
      await s.queueTarget(const TabLinkTarget(ArulTab.ringtones));
      expect(s.pendingTarget, isNull);
      expect(
        ArulDeepLink.pendingTarget,
        const TabLinkTarget(ArulTab.ringtones),
      );
    });

    test('an invalid id or language is refused at the door', () async {
      final s = await service();
      await s.queueTarget(const WallpaperLinkTarget('not-a-uuid'));
      await s.queueLocale('fr');
      expect(s.pendingTarget, isNull);
      expect(s.pendingLang, isNull);
      expect(ArulDeepLink.pendingTarget, isNull);
    });

    test(
      'clearPendingTarget / clearPendingLang drop the persisted copies',
      () async {
        final s = await service({
          'pending_deeplink_ringtone': rid,
          'pending_deeplink_source': 'meta',
          'pending_deeplink_lang': 'te',
        });
        expect(
          s.pendingTarget,
          const RingtoneLinkTarget(rid, source: DeepLinkSource.meta),
        );
        await s.clearPendingTarget();
        await s.clearPendingLang();
        expect(s.pendingTarget, isNull);
        expect(s.pendingLang, isNull);
      },
    );
  });
}
