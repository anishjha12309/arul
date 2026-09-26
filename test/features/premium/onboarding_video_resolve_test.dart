import 'package:arul/data/models/app_config_model.dart';
import 'package:arul/features/premium/domain/onboarding_video.dart';
import 'package:flutter_test/flutter_test.dart';

AppConfigModel _config(Map<String, dynamic> flags) =>
    AppConfigModel(prices: const {}, policyUrls: const {}, featureFlags: flags);

/// An ad can carry any of the six locales but only five cuts exist -> a wrong resolve is a 404 or the wrong language.
void main() {
  group('resolveOnboardingVideo', () {
    test('serves the requested language when a cut exists', () {
      final source = resolveOnboardingVideo(_config({}), 'ta');
      expect(source, isNotNull);
      expect(source!.lang, 'ta');
      expect(source.url, endsWith('/onboarding/ta.mp4'));
    });

    test('falls back to English for a locale with no cut', () {
      // `hi` is a live ad language with no dub yet -> degrade to English, never request a key that does not exist.
      final source = resolveOnboardingVideo(_config({}), 'hi');
      expect(source?.lang, 'en');
    });

    test('reports the language actually played, not the one asked for', () {
      // Analytics attributes the cut that RAN -> a `hi` link reporting "hi" would hide that nobody heard a Hindi pitch.
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

  group('resolveReturnVideo', () {
    test('lives in its own folder, one cut per language', () {
      expect(
        resolveReturnVideo(_config({}), 'kn')?.url,
        endsWith('/onboarding/return/kn.mp4'),
      );
    });

    test('Hindi plays the English cut, as the onboarding clip does', () {
      expect(resolveReturnVideo(_config({}), 'hi')?.lang, 'en');
    });

    test('its switch is its own — turning onboarding off leaves it on', () {
      final config = _config({
        'onboarding_video': {'enabled': false},
      });
      expect(resolveReturnVideo(config, 'ta'), isNotNull);
      expect(returnPageEnabled(config), isTrue);
    });

    test('return_video.enabled:false turns the whole page off', () {
      final config = _config({
        'return_video': {'enabled': false},
      });
      expect(resolveReturnVideo(config, 'ta'), isNull);
      expect(returnPageEnabled(config), isFalse);
    });

    test('an absent config is ON — a cold start must not lose the page', () {
      expect(returnPageEnabled(null), isTrue);
      expect(resolveReturnVideo(null, 'ml')?.lang, 'ml');
    });

    test('its version busts only its own cache', () {
      final config = _config({
        'return_video': {'version': 3},
      });
      expect(resolveReturnVideo(config, 'ta')?.url, endsWith('ta.mp4?v=3'));
      expect(resolveOnboardingVideo(config, 'ta')?.url, endsWith('ta.mp4'));
    });
  });
}
