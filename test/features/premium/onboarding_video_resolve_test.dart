import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/features/premium/domain/onboarding_video.dart';
import 'package:flutter_test/flutter_test.dart';

AppConfigModel _config(Map<String, dynamic> flags) =>
    AppConfigModel(prices: const {}, policyUrls: const {}, featureFlags: flags);

/// The fallback ladder is the whole risk here: an ad can carry any of the six
/// locales, only five cuts exist, and getting it wrong means either a 404 where
/// a video was promised or the wrong language talking at the user.
void main() {
  group('resolveOnboardingVideo', () {
    test('serves the requested language when a cut exists', () {
      final source = resolveOnboardingVideo(_config({}), 'ta');
      expect(source, isNotNull);
      expect(source!.lang, 'ta');
      expect(source.url, endsWith('/onboarding/ta.mp4'));
    });

    test('falls back to English for a locale with no cut', () {
      // `hi` is a live ad language with no dub produced yet. It must degrade to
      // English, never request a key that does not exist.
      final source = resolveOnboardingVideo(_config({}), 'hi');
      expect(source?.lang, 'en');
    });

    test('reports the language actually played, not the one asked for', () {
      // Analytics attributes the cut that ran; a `hi` link reporting "hi" would
      // hide the fact that nobody has ever heard a Hindi pitch.
      expect(resolveOnboardingVideo(_config({}), 'hi')?.lang, 'en');
    });

    test('missing config still resolves — a slow /config must not gate it', () {
      expect(resolveOnboardingVideo(null, 'te')?.lang, 'te');
    });

    test('enabled:false is the kill switch', () {
      final config = _config({
        'onboarding_video': {'enabled': false},
      });
      expect(resolveOnboardingVideo(config, 'ta'), isNull);
    });

    test('remote langs list wins, so shipping a dub needs no release', () {
      final config = _config({
        'onboarding_video': {
          'langs': ['en', 'ta', 'te', 'kn', 'ml', 'hi'],
        },
      });
      expect(resolveOnboardingVideo(config, 'hi')?.lang, 'hi');
    });

    test('version becomes ?v=, the cache-bust that replaces a purge', () {
      final config = _config({
        'onboarding_video': {'version': 7},
      });
      expect(resolveOnboardingVideo(config, 'ta')?.url, endsWith('.mp4?v=7'));
    });

    test('no version means no query string', () {
      expect(resolveOnboardingVideo(_config({}), 'ta')?.url, endsWith('.mp4'));
    });

    test('a langs list without English resolves nothing for an odd locale', () {
      // The caller puts the brand lockup back rather than showing a broken box.
      final config = _config({
        'onboarding_video': {
          'langs': ['ta'],
        },
      });
      expect(resolveOnboardingVideo(config, 'kn'), isNull);
    });
  });
}
