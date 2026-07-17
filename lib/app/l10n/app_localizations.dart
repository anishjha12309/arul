import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_hi.dart';
import 'app_localizations_kn.dart';
import 'app_localizations_ml.dart';
import 'app_localizations_ta.dart';
import 'app_localizations_te.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ta'),
    Locale('te'),
    Locale('kn'),
    Locale('ml'),
    Locale('hi'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Arul'**
  String get appName;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'SOUTH INDIAN WALLPAPERS'**
  String get appTagline;

  /// No description provided for @categoryAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get categoryAll;

  /// No description provided for @feedLiveBadge.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get feedLiveBadge;

  /// No description provided for @feedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get feedEmptyTitle;

  /// No description provided for @feedEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Try another category.'**
  String get feedEmptyBody;

  /// No description provided for @feedErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load wallpapers'**
  String get feedErrorTitle;

  /// No description provided for @feedErrorBody.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get feedErrorBody;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong.'**
  String get errorGeneric;

  /// No description provided for @signInHeadline.
  ///
  /// In en, this message translates to:
  /// **'Wallpapers worth waking up to'**
  String get signInHeadline;

  /// No description provided for @signInBody.
  ///
  /// In en, this message translates to:
  /// **'Sign in to apply, share and keep your collection across devices.'**
  String get signInBody;

  /// No description provided for @signInGoogle.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get signInGoogle;

  /// No description provided for @signInTerms.
  ///
  /// In en, this message translates to:
  /// **'By continuing you agree to our Terms and Privacy Policy.'**
  String get signInTerms;

  /// No description provided for @premiumTitle.
  ///
  /// In en, this message translates to:
  /// **'Premium'**
  String get premiumTitle;

  /// No description provided for @premiumHeadline.
  ///
  /// In en, this message translates to:
  /// **'Unlock every wallpaper'**
  String get premiumHeadline;

  /// No description provided for @premiumSub.
  ///
  /// In en, this message translates to:
  /// **'Browsing is always free. Premium is for making them yours.'**
  String get premiumSub;

  /// No description provided for @premiumBenefitApply.
  ///
  /// In en, this message translates to:
  /// **'Apply any wallpaper, static or live'**
  String get premiumBenefitApply;

  /// No description provided for @premiumBenefitLive.
  ///
  /// In en, this message translates to:
  /// **'Live video wallpapers in full quality'**
  String get premiumBenefitLive;

  /// No description provided for @premiumBenefitShare.
  ///
  /// In en, this message translates to:
  /// **'Share wallpapers with friends and family'**
  String get premiumBenefitShare;

  /// No description provided for @premiumBenefitNew.
  ///
  /// In en, this message translates to:
  /// **'New wallpapers added every week'**
  String get premiumBenefitNew;

  /// No description provided for @premiumPrice.
  ///
  /// In en, this message translates to:
  /// **'₹199 / month'**
  String get premiumPrice;

  /// No description provided for @premiumCta.
  ///
  /// In en, this message translates to:
  /// **'Start free trial'**
  String get premiumCta;

  /// No description provided for @premiumTrialNote.
  ///
  /// In en, this message translates to:
  /// **'One free trial per account. Cancel anytime — you keep access until the period ends.'**
  String get premiumTrialNote;

  /// No description provided for @premiumComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Payments arrive with the backend.'**
  String get premiumComingSoon;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @settingsContent.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get settingsContent;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsSupport.
  ///
  /// In en, this message translates to:
  /// **'Need help'**
  String get settingsSupport;

  /// No description provided for @settingsPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get settingsPrivacy;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// No description provided for @uploadTitle.
  ///
  /// In en, this message translates to:
  /// **'Upload your content'**
  String get uploadTitle;

  /// No description provided for @uploadBody.
  ///
  /// In en, this message translates to:
  /// **'Share your own wallpaper with the community. We review every submission before it goes live.'**
  String get uploadBody;

  /// No description provided for @uploadPickCategory.
  ///
  /// In en, this message translates to:
  /// **'Choose a category'**
  String get uploadPickCategory;

  /// No description provided for @uploadPickFile.
  ///
  /// In en, this message translates to:
  /// **'Choose a file'**
  String get uploadPickFile;

  /// No description provided for @uploadSpecNote.
  ///
  /// In en, this message translates to:
  /// **'Photos: 1080×1920. Videos: 1024×1824, no audio, under 50 MB.'**
  String get uploadSpecNote;

  /// No description provided for @uploadComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Uploads arrive with the backend.'**
  String get uploadComingSoon;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @applyTargetTitle.
  ///
  /// In en, this message translates to:
  /// **'Set wallpaper on'**
  String get applyTargetTitle;

  /// No description provided for @applyTargetHome.
  ///
  /// In en, this message translates to:
  /// **'Home screen'**
  String get applyTargetHome;

  /// No description provided for @applyTargetLock.
  ///
  /// In en, this message translates to:
  /// **'Lock screen'**
  String get applyTargetLock;

  /// No description provided for @applyTargetBoth.
  ///
  /// In en, this message translates to:
  /// **'Home and lock screen'**
  String get applyTargetBoth;

  /// No description provided for @applied.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper applied'**
  String get applied;

  /// No description provided for @offlineBody.
  ///
  /// In en, this message translates to:
  /// **'You\'re offline. Check your connection and try again.'**
  String get offlineBody;

  /// No description provided for @offlineTitle.
  ///
  /// In en, this message translates to:
  /// **'No internet'**
  String get offlineTitle;

  /// No description provided for @offlineFeedBody.
  ///
  /// In en, this message translates to:
  /// **'Turn on the internet to see wallpapers.'**
  String get offlineFeedBody;

  /// No description provided for @shareMessage.
  ///
  /// In en, this message translates to:
  /// **'Beautiful South Indian wallpapers — get Arul: https://hsrapps.com/arul'**
  String get shareMessage;

  /// Text shared to WhatsApp / the system share sheet
  ///
  /// In en, this message translates to:
  /// **'Beautiful South Indian wallpapers, still and live — I\'m loving Arul. Install it with my link and I\'ll earn free premium: {link}'**
  String referShareMessage(String link);

  /// No description provided for @tabWallpapers.
  ///
  /// In en, this message translates to:
  /// **'Wallpapers'**
  String get tabWallpapers;

  /// No description provided for @tabRingtones.
  ///
  /// In en, this message translates to:
  /// **'Ringtones'**
  String get tabRingtones;

  /// No description provided for @ringtoneSet.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get ringtoneSet;

  /// No description provided for @ringtonePreviewSemantic.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get ringtonePreviewSemantic;

  /// No description provided for @ringtonePreviewUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Preview not available yet'**
  String get ringtonePreviewUnavailable;

  /// No description provided for @ringtonesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Ringtones are coming soon'**
  String get ringtonesEmptyTitle;

  /// No description provided for @ringtonesEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Devotional ringtones are on their way. Check back soon.'**
  String get ringtonesEmptyBody;

  /// No description provided for @ringtonesErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load ringtones'**
  String get ringtonesErrorTitle;

  /// No description provided for @ringtoneSetSuccess.
  ///
  /// In en, this message translates to:
  /// **'Ringtone set. If it doesn\'t appear, restart your phone.'**
  String get ringtoneSetSuccess;

  /// No description provided for @ringtoneSetFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t set the ringtone. Please try again.'**
  String get ringtoneSetFailed;

  /// No description provided for @ringtonePermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Permission needed'**
  String get ringtonePermissionTitle;

  /// No description provided for @ringtonePermissionBody.
  ///
  /// In en, this message translates to:
  /// **'To set a ringtone, allow Arul to change system settings.'**
  String get ringtonePermissionBody;

  /// No description provided for @ringtonePermissionCta.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get ringtonePermissionCta;

  /// No description provided for @ringtonePermissionCancel.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get ringtonePermissionCancel;

  /// No description provided for @ringtoneSetPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get ringtoneSetPreparing;

  /// No description provided for @ringtoneSetDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get ringtoneSetDownloading;

  /// No description provided for @ringtoneSetApplying.
  ///
  /// In en, this message translates to:
  /// **'Setting ringtone…'**
  String get ringtoneSetApplying;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'en',
    'hi',
    'kn',
    'ml',
    'ta',
    'te',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'hi':
      return AppLocalizationsHi();
    case 'kn':
      return AppLocalizationsKn();
    case 'ml':
      return AppLocalizationsMl();
    case 'ta':
      return AppLocalizationsTa();
    case 'te':
      return AppLocalizationsTe();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
