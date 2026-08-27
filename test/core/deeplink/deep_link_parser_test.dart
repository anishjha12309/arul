// The one parser every delivery path goes through: App Link intents, Meta's
// fb<APP_ID>://open scheme, the deferred URLs GA4F / the Meta SDK fetch, and
// the Play Install Referrer payload the Worker writes. Pins the two link shapes
// the ad team pastes (docs/deep-links.md) and the validation that keeps an
// outside string from selecting a row it should not.

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/deeplink/deep_link_parser.dart';
import 'package:arul/core/deeplink/deep_link_target.dart';

const _w = '95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f';
const _r = '0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d';

DeepLinkRequest? _parse(String url) =>
    parseDeepLink(url, source: DeepLinkSource.appLink);

void main() {
  group('https App Links on our host', () {
    test('/w/<uuid> is a wallpaper', () {
      final req = _parse('https://arul.hsrutility.com/w/$_w');
      expect(req?.target, const WallpaperLinkTarget(_w));
      expect(req?.lang, isNull);
    });

    test('/r/<uuid> is a ringtone', () {
      final req = _parse('https://arul.hsrutility.com/r/$_r');
      expect(req?.target, const RingtoneLinkTarget(_r));
    });

    test('?lang= rides along, normalised to a shipped code', () {
      final req = _parse('https://arul.hsrutility.com/w/$_w?lang=HI');
      expect(req?.target, const WallpaperLinkTarget(_w));
      expect(req?.lang, 'hi');
      expect(
        _parse(
          'https://arul.hsrutility.com/r/$_r?ref=ABCD1234&lang=ta-IN',
        )?.lang,
        'ta',
        reason: 'region tags are pasted by hand and must not break the code',
      );
    });

    test('an unknown language is dropped, the target is kept', () {
      final req = _parse('https://arul.hsrutility.com/w/$_w?lang=fr');
      expect(req?.target, const WallpaperLinkTarget(_w));
      expect(req?.lang, isNull);
    });

    test('a language alone is still a request', () {
      // A creative may want the app in Tamil without naming content.
      final req = _parse('https://arul.hsrutility.com/w/not-a-uuid?lang=ta');
      expect(req?.target, isNull);
      expect(req?.lang, 'ta');
    });

    test('the id-less campaign form is a language-only request', () {
      // `/w/?lang=hi` — what a language-only ad pastes. The manifest filter is a
      // pathPrefix, so Android hands this to the app exactly like a full link.
      final req = _parse('https://arul.hsrutility.com/w/?lang=hi');
      expect(req?.target, isNull);
      expect(req?.lang, 'hi');
      expect(_parse('https://arul.hsrutility.com/r/?lang=ta')?.lang, 'ta');
    });

    test('ilang is IGNORED here — a share must not re-language an install', () {
      // The whole point of the separate key: this is the tap of someone who
      // ALREADY has Arul, and their own Settings choice outranks a friend's.
      // Only the Play referrer honours it (the Worker folds it into `lang=`).
      final req = _parse(
        'https://arul.hsrutility.com/w/$_w?ref=ABCD1234&ilang=ta',
      );
      expect(req?.target, const WallpaperLinkTarget(_w));
      expect(req?.lang, isNull);
    });

    test('ilang alone is not a request at all', () {
      expect(_parse('https://arul.hsrutility.com/w/?ilang=ta'), isNull);
    });

    test('the UUID is normalised and a trailing slash is tolerated', () {
      // android.net.Uri drops empty segments, so the native validator passes a
      // campaign URL written with a trailing slash; Dart must agree.
      expect(
        _parse('https://arul.hsrutility.com/w/${_w.toUpperCase()}/')?.target,
        const WallpaperLinkTarget(_w),
      );
    });

    test('carries the source it was delivered by', () {
      final req = parseDeepLink(
        'https://arul.hsrutility.com/r/$_r',
        source: DeepLinkSource.googleAds,
      );
      expect(req?.target?.source, DeepLinkSource.googleAds);
    });

    test('rejects another host, scheme, path or a malformed id', () {
      for (final link in [
        'http://arul.hsrutility.com/w/$_w',
        'https://evil.example/w/$_w',
        'https://arul.hsrutility.com/x/$_w',
        'https://arul.hsrutility.com/w/not-a-uuid',
        'https://arul.hsrutility.com/w/$_w/extra',
        'https://arul.hsrutility.com/',
        '',
        'not a url at all',
      ]) {
        expect(_parse(link), isNull, reason: 'must reject $link');
      }
    });
  });

  group("Meta's fb<APP_ID>://open scheme (the reference format, verbatim)", () {
    test('wallpaper_id + lang', () {
      final req = _parse('fb875866992041168://open?wallpaper_id=$_w&lang=hi');
      expect(req?.target, const WallpaperLinkTarget(_w));
      expect(req?.lang, 'hi');
    });

    test('screen=ringtones + ringtone_id + lang', () {
      final req = _parse(
        'fb875866992041168://open?screen=ringtones&ringtone_id=$_r&lang=hi',
      );
      expect(req?.target, const RingtoneLinkTarget(_r));
      expect(req?.lang, 'hi');
    });

    test('screen alone switches the tab', () {
      expect(
        _parse('fb875866992041168://open?screen=ringtones&lang=te')?.target,
        const TabLinkTarget(ArulTab.ringtones),
      );
      expect(
        _parse('fb875866992041168://open?screen=wallpaper')?.target,
        const TabLinkTarget(ArulTab.wallpapers),
      );
      // The singular alias the reference apps accept too.
      expect(
        _parse('fb875866992041168://open?screen=ringtone')?.target,
        const TabLinkTarget(ArulTab.ringtones),
      );
    });

    test("a reference screen Arul doesn't have is ignored", () {
      // `status` / `prayers` are Noor/Shubh tabs; only lang survives.
      final req = _parse('fb875866992041168://open?screen=status&lang=hi');
      expect(req?.target, isNull);
      expect(req?.lang, 'hi');
      expect(_parse('fb875866992041168://open?screen=prayers'), isNull);
    });

    test('an id beats a contradicting screen', () {
      expect(
        _parse('fb1://open?screen=wallpaper&ringtone_id=$_r')?.target,
        const RingtoneLinkTarget(_r),
      );
    });

    test('requires the open host and the fb<digits> scheme', () {
      expect(_parse('fb1://other?wallpaper_id=$_w'), isNull);
      expect(_parse('fbx://open?wallpaper_id=$_w'), isNull);
      expect(_parse('arul://open?wallpaper_id=$_w'), isNull);
    });

    test('a malformed id on the scheme is dropped', () {
      expect(_parse('fb1://open?wallpaper_id=../../etc'), isNull);
    });
  });

  group('query form on our own host', () {
    test('wallpaper_id / ringtone_id are accepted on https too', () {
      // Belt and braces: a creative built in the reference style but on our
      // host still resolves. The path form is what we document.
      expect(
        _parse('https://arul.hsrutility.com/?wallpaper_id=$_w')?.target,
        const WallpaperLinkTarget(_w),
      );
      expect(
        _parse('https://arul.hsrutility.com/?ringtone_id=$_r&lang=ml')?.lang,
        'ml',
      );
    });
  });

  group('Play Install Referrer payload', () {
    test('w= + lang= (the Worker /w/:id redirect)', () {
      final req = parseReferrerPayload('ref=ABCD1234&w=$_w&lang=hi');
      expect(
        req?.target,
        const WallpaperLinkTarget(_w, source: DeepLinkSource.installReferrer),
      );
      expect(req?.lang, 'hi');
    });

    test('r= (the Worker /r/:id redirect)', () {
      expect(
        parseReferrerPayload('r=$_r')?.target,
        const RingtoneLinkTarget(_r, source: DeepLinkSource.installReferrer),
      );
    });

    test('finds the keys among utm params Play may append', () {
      final req = parseReferrerPayload(
        'utm_source=fb&w=$_w&utm_medium=cpc&lang=kn',
      );
      expect(req?.target, isA<WallpaperLinkTarget>());
      expect(req?.lang, 'kn');
    });

    test('the reference key names work in a referrer too', () {
      expect(
        parseReferrerPayload('wallpaper_id=$_w')?.target,
        isA<WallpaperLinkTarget>(),
      );
    });

    test('nothing usable → null', () {
      for (final raw in [
        null,
        '',
        '   ',
        'ref=ABCD1234',
        'w=not-a-uuid',
        'organic',
        'utm_source=google-play&utm_medium=organic',
        'lang=xx',
      ]) {
        expect(parseReferrerPayload(raw), isNull, reason: 'must ignore "$raw"');
      }
    });
  });

  group('normalizeLang', () {
    test(
      'accepts exactly the six shipped codes, case- and region-insensitive',
      () {
        for (final code in ['en', 'ta', 'te', 'kn', 'ml', 'hi']) {
          expect(normalizeLang(code), code);
          expect(normalizeLang(code.toUpperCase()), code);
          expect(normalizeLang('$code-IN'), code);
          expect(normalizeLang('${code}_IN'), code);
        }
        for (final junk in ['fr', 'hindi', '', ' ', null, 'h', 'hi-']) {
          expect(normalizeLang(junk), junk == 'hi-' ? 'hi' : isNull);
        }
      },
    );
  });
}
