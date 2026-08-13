// Unit tests for InstallReferrerService.parseReferralCode — the pure parsing of
// a Play Install Referrer payload into our referral code. No platform channel.

import 'package:flutter_test/flutter_test.dart';
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
  // app. The Worker's /w/:id sends them to Play with `ref=<code>&w=<id>`, Play
  // replays it on first launch, and these turn it back into a wallpaper.
  group('InstallReferrerService.parseWallpaperTarget', () {
    const id = '95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f';

    test('extracts w= from the payload the Worker builds', () {
      expect(
        InstallReferrerService.parseWallpaperTarget('ref=ABCD1234&w=$id'),
        id,
      );
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

    test('the host matches the one the app builds links for', () {
      // Three places must agree or verification fails silently and every link
      // opens a browser: this constant, AndroidManifest's android:host, and the
      // wrangler.toml custom domain.
      expect(kDeepLinkHost, 'arul.hsrutility.com');
    });
  });
}
