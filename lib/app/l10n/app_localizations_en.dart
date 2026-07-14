// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Arul';

  @override
  String get appTagline => 'SOUTH INDIAN WALLPAPERS';

  @override
  String get categoryAll => 'All';

  @override
  String get feedLiveBadge => 'Live';

  @override
  String get feedEmptyTitle => 'Nothing here yet';

  @override
  String get feedEmptyBody => 'Try another category.';

  @override
  String get feedErrorTitle => 'Couldn\'t load wallpapers';

  @override
  String get feedErrorBody => 'Check your connection and try again.';

  @override
  String get retry => 'Retry';

  @override
  String get errorGeneric => 'Something went wrong.';

  @override
  String get signInHeadline => 'Wallpapers worth waking up to';

  @override
  String get signInBody =>
      'Sign in to apply, share and keep your collection across devices.';

  @override
  String get signInGoogle => 'Continue with Google';

  @override
  String get signInTerms =>
      'By continuing you agree to our Terms and Privacy Policy.';

  @override
  String get premiumTitle => 'Premium';

  @override
  String get premiumHeadline => 'Unlock every wallpaper';

  @override
  String get premiumSub =>
      'Browsing is always free. Premium is for making them yours.';

  @override
  String get premiumBenefitApply => 'Apply any wallpaper, static or live';

  @override
  String get premiumBenefitLive => 'Live video wallpapers in full quality';

  @override
  String get premiumBenefitShare => 'Share wallpapers with friends and family';

  @override
  String get premiumBenefitNew => 'New wallpapers added every week';

  @override
  String get premiumPrice => '₹199 / month';

  @override
  String get premiumCta => 'Start free trial';

  @override
  String get premiumTrialNote =>
      'One free trial per account. Cancel anytime — you keep access until the period ends.';

  @override
  String get premiumComingSoon => 'Payments arrive with the backend.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get settingsContent => 'Content';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsSupport => 'Need help';

  @override
  String get settingsPrivacy => 'Privacy policy';

  @override
  String get settingsVersion => 'Version';

  @override
  String get uploadTitle => 'Upload your content';

  @override
  String get uploadBody =>
      'Share your own wallpaper with the community. We review every submission before it goes live.';

  @override
  String get uploadPickCategory => 'Choose a category';

  @override
  String get uploadPickFile => 'Choose a file';

  @override
  String get uploadSpecNote =>
      'Photos: 1080×1920. Videos: 1024×1824, no audio, under 50 MB.';

  @override
  String get uploadComingSoon => 'Uploads arrive with the backend.';

  @override
  String get apply => 'Apply';

  @override
  String get share => 'Share';

  @override
  String get applyTargetTitle => 'Set wallpaper on';

  @override
  String get applyTargetHome => 'Home screen';

  @override
  String get applyTargetLock => 'Lock screen';

  @override
  String get applyTargetBoth => 'Home and lock screen';

  @override
  String get applied => 'Wallpaper applied';

  @override
  String get offlineBody =>
      'You\'re offline. Check your connection and try again.';

  @override
  String get offlineTitle => 'No internet';

  @override
  String get offlineFeedBody => 'Turn on the internet to see wallpapers.';

  @override
  String get shareMessage =>
      'Beautiful South Indian wallpapers — get Arul: https://hsrapps.com/arul';

  @override
  String referShareMessage(String link) {
    return 'Beautiful South Indian wallpapers, still and live — I\'m loving Arul. Install it with my link and I\'ll earn free premium: $link';
  }
}
