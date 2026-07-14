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
      expect(link, contains('id=com.hsrapps.arul'));
      // "ref=ABCD1234" URL-encoded → "ref%3DABCD1234".
      expect(link, contains('referrer=ref%3DABCD1234'));
      // Round-trips back to the same code.
      final referrer = Uri.parse(link).queryParameters['referrer'];
      expect(InstallReferrerService.parseReferralCode(referrer), 'ABCD1234');
    });
  });
}
