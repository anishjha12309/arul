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

  /// The first browse chip on both tabs. ONE short everyday word.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get categoryAll;

  /// The New chip beside All on both browse rows — a WINDOW of recent items, not a category. ONE short everyday word for "new (ones)".
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get categoryNew;

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

  /// Outlined pill under the empty-category state; taps back to the All chip. A short verb phrase ("see all").
  ///
  /// In en, this message translates to:
  /// **'Browse all'**
  String get feedBrowseAll;

  /// One line under the gopuram while the first catalog page loads. Short; on screen for well under a second on a warm cache.
  ///
  /// In en, this message translates to:
  /// **'Bringing your wallpapers…'**
  String get feedLoadingBody;

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

  /// Compact pill with a refresh icon under every error card. ONE or two short words ("again" reads fine beside the icon).
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong.'**
  String get errorGeneric;

  /// No description provided for @signInCaption.
  ///
  /// In en, this message translates to:
  /// **'Bring the divine home'**
  String get signInCaption;

  /// No description provided for @signInGoogle.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get signInGoogle;

  /// No description provided for @signInSubtitleIdle.
  ///
  /// In en, this message translates to:
  /// **'Choose an account to start'**
  String get signInSubtitleIdle;

  /// No description provided for @signInSubtitleExchanging.
  ///
  /// In en, this message translates to:
  /// **'Signing you in…'**
  String get signInSubtitleExchanging;

  /// No description provided for @signInNudgeRetry.
  ///
  /// In en, this message translates to:
  /// **'Click here to sign in'**
  String get signInNudgeRetry;

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

  /// Upload screen title; the slot is tight even for English at 320 dp. Two short words at most ("Upload").
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

  /// Label under the phone icon on the third apply-target card (Home / Lock / Both). The three cards share one row on a 360 dp phone, ~100 dp each — ONE short everyday word meaning 'both'.
  ///
  /// In en, this message translates to:
  /// **'Both'**
  String get applyTargetBoth;

  /// No description provided for @applied.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper applied'**
  String get applied;

  /// Toast after a LIVE wallpaper was applied as its own first frame, because the device has no live-wallpaper support at all. It must say BOTH things — the phone's limit, and that something was in fact applied — or the user reads a still image where they picked motion as a broken app.
  ///
  /// In en, this message translates to:
  /// **'Live wallpapers aren\'t supported on this phone, so we set a still image instead.'**
  String get appliedLiveFallback;

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

  /// Caption attached to a shared wallpaper FILE. The recipient is already looking at the image, so this does not describe it — it says where more came from. ONE short line, then the install link alone on the last line: messengers preview a trailing link and bury an inline one. NEVER put a second URL anywhere in this string; the link placeholder is referral-attributed and a competing marketing-site link (which this string used to carry) sends the tap somewhere that earns the sender nothing.
  ///
  /// In en, this message translates to:
  /// **'More devotional wallpapers like this one — still and live — on Arul:\n{link}'**
  String wallpaperShareCaption(String link);

  /// Text the user sends a friend via WhatsApp / the system share sheet, and the copy behind every 'Tell a friend' entry point. Written in the SENDER's voice: first-person, natural, and it must NOT mention the sender's referral reward — 'install this so I get free premium' reads as self-serving and suppresses the tap. Link alone on the last line.
  ///
  /// In en, this message translates to:
  /// **'I\'ve been using Arul for South Indian devotional wallpapers — Amman, Murugan, Perumal, Sivan, and live ones that actually move. Thought you\'d like it.\n\n{link}'**
  String referShareMessage(String link);

  /// No description provided for @tabWallpapers.
  ///
  /// In en, this message translates to:
  /// **'Wallpapers'**
  String get tabWallpapers;

  /// Dock tab label AND the Ringtones screen title. The dock cell is 58 dp wide and the title shares its band with the Earn chip — use the short everyday (often singular, transliterated) word, never a long plural.
  ///
  /// In en, this message translates to:
  /// **'Ringtones'**
  String get tabRingtones;

  /// Label on the pill in the Ringtones header that opens Refer & Earn. Very tight space (a 38px chip beside the screen title) — keep it to ONE short word; it is a call to action, not a noun phrase.
  ///
  /// In en, this message translates to:
  /// **'Earn'**
  String get earn;

  /// The Set pill on every ringtone row, max 120 dp wide. ONE short verb; the transliterated "set" is fine where that is what people say.
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

  /// Toast shown when a ringtone preview is tapped while the phone’s media volume is at zero or it is on silent — nothing would be heard, so the preview does not start. Keep it an instruction, not an error.
  ///
  /// In en, this message translates to:
  /// **'Turn up the volume to hear this preview'**
  String get ringtoneVolumeMuted;

  /// Tiny badge on the ringtone row that is the phone’s CURRENT ringtone. One short word; it sits in a pill a few characters wide.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get ringtoneCurrentBadge;

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

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @errorGenericRetry.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorGenericRetry;

  /// No description provided for @settingsFallbackName.
  ///
  /// In en, this message translates to:
  /// **'Your account'**
  String get settingsFallbackName;

  /// No description provided for @settingsFallbackEmail.
  ///
  /// In en, this message translates to:
  /// **'Signed in with Google'**
  String get settingsFallbackEmail;

  /// No description provided for @settingsPremiumSubTrial.
  ///
  /// In en, this message translates to:
  /// **'You\'re on the free trial'**
  String get settingsPremiumSubTrial;

  /// No description provided for @settingsPremiumSubCancelled.
  ///
  /// In en, this message translates to:
  /// **'Auto-renew off · access continues'**
  String get settingsPremiumSubCancelled;

  /// No description provided for @settingsPremiumSubActive.
  ///
  /// In en, this message translates to:
  /// **'You\'re a member'**
  String get settingsPremiumSubActive;

  /// No description provided for @settingsReferSub.
  ///
  /// In en, this message translates to:
  /// **'Earn 30 days free premium'**
  String get settingsReferSub;

  /// No description provided for @settingsTellFriend.
  ///
  /// In en, this message translates to:
  /// **'Tell a friend'**
  String get settingsTellFriend;

  /// No description provided for @settingsTellFriendSub.
  ///
  /// In en, this message translates to:
  /// **'Send Arul to someone who would love it'**
  String get settingsTellFriendSub;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsTheme;

  /// No description provided for @settingsNeedHelp.
  ///
  /// In en, this message translates to:
  /// **'Need help?'**
  String get settingsNeedHelp;

  /// No description provided for @settingsNeedHelpSub.
  ///
  /// In en, this message translates to:
  /// **'Support and subscription'**
  String get settingsNeedHelpSub;

  /// No description provided for @settingsHelpSupport.
  ///
  /// In en, this message translates to:
  /// **'Contact support'**
  String get settingsHelpSupport;

  /// No description provided for @settingsHelpSupportSub.
  ///
  /// In en, this message translates to:
  /// **'Write to us by email'**
  String get settingsHelpSupportSub;

  /// No description provided for @settingsHelpManage.
  ///
  /// In en, this message translates to:
  /// **'Manage subscription'**
  String get settingsHelpManage;

  /// No description provided for @settingsHelpDeleteSub.
  ///
  /// In en, this message translates to:
  /// **'Remove your account'**
  String get settingsHelpDeleteSub;

  /// No description provided for @settingsUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload your content'**
  String get settingsUpload;

  /// No description provided for @settingsUploadSub.
  ///
  /// In en, this message translates to:
  /// **'Share a wallpaper or ringtone'**
  String get settingsUploadSub;

  /// No description provided for @settingsLogout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get settingsLogout;

  /// No description provided for @settingsLogoutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Logout?'**
  String get settingsLogoutConfirmTitle;

  /// No description provided for @settingsLogoutConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'You can sign back in anytime with Google.'**
  String get settingsLogoutConfirmBody;

  /// No description provided for @settingsDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get settingsDeleteAccount;

  /// No description provided for @settingsDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account?'**
  String get settingsDeleteConfirmTitle;

  /// No description provided for @settingsDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This can\'t be undone.'**
  String get settingsDeleteConfirmBody;

  /// No description provided for @settingsDeleteConfirmBodyPremium.
  ///
  /// In en, this message translates to:
  /// **'Premium ends now. The days left aren\'t refunded, and a new account won\'t get a free trial.'**
  String get settingsDeleteConfirmBodyPremium;

  /// No description provided for @settingsTerms.
  ///
  /// In en, this message translates to:
  /// **'Terms & Conditions'**
  String get settingsTerms;

  /// No description provided for @settingsRefund.
  ///
  /// In en, this message translates to:
  /// **'Refund policy'**
  String get settingsRefund;

  /// No description provided for @settingsSupportEmailPrompt.
  ///
  /// In en, this message translates to:
  /// **'Please describe your issue or feedback:'**
  String get settingsSupportEmailPrompt;

  /// No description provided for @settingsSupportEmailDetails.
  ///
  /// In en, this message translates to:
  /// **'The details below help us resolve your request faster:'**
  String get settingsSupportEmailDetails;

  /// Error toast when no mail client can handle the mailto: intent. Names the support address so the user can copy it by hand — without it the tap on "Need help?" simply does nothing.
  ///
  /// In en, this message translates to:
  /// **'No email app found. Write to us at {email}'**
  String settingsNoEmailApp(String email);

  /// No description provided for @settingsEditNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get settingsEditNameTitle;

  /// No description provided for @settingsEditNameSub.
  ///
  /// In en, this message translates to:
  /// **'Shown on wallpapers you upload'**
  String get settingsEditNameSub;

  /// No description provided for @themeSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get themeSystemDefault;

  /// No description provided for @themeSystemSub.
  ///
  /// In en, this message translates to:
  /// **'Follow device setting'**
  String get themeSystemSub;

  /// No description provided for @themeLightSub.
  ///
  /// In en, this message translates to:
  /// **'Ivory & silk'**
  String get themeLightSub;

  /// No description provided for @themeDarkSub.
  ///
  /// In en, this message translates to:
  /// **'Lamp-lit maroon'**
  String get themeDarkSub;

  /// No description provided for @remindersTimeLabel.
  ///
  /// In en, this message translates to:
  /// **'Reminder time'**
  String get remindersTimeLabel;

  /// No description provided for @premiumScreenSubline.
  ///
  /// In en, this message translates to:
  /// **'The full collection, alive on your screen'**
  String get premiumScreenSubline;

  /// No description provided for @premiumPerkEvery.
  ///
  /// In en, this message translates to:
  /// **'Every wallpaper, still and live'**
  String get premiumPerkEvery;

  /// No description provided for @premiumPerkApplyShare.
  ///
  /// In en, this message translates to:
  /// **'Apply and share without limits'**
  String get premiumPerkApplyShare;

  /// No description provided for @premiumPerkNew.
  ///
  /// In en, this message translates to:
  /// **'New arrivals every week'**
  String get premiumPerkNew;

  /// No description provided for @premiumPerMonth.
  ///
  /// In en, this message translates to:
  /// **'/ month'**
  String get premiumPerMonth;

  /// No description provided for @premiumPlanNote.
  ///
  /// In en, this message translates to:
  /// **'UPI Autopay · cancel anytime'**
  String get premiumPlanNote;

  /// No description provided for @premiumTrialPill.
  ///
  /// In en, this message translates to:
  /// **'1 DAY FREE'**
  String get premiumTrialPill;

  /// No description provided for @premiumCtaPaid.
  ///
  /// In en, this message translates to:
  /// **'Get Premium'**
  String get premiumCtaPaid;

  /// Paywall footnote for a user who still has their one free trial. The ₹2 PENNY_DROP is named on purpose: the user SEES ₹2 leave their account during UPI mandate setup, and an unexplained debit on a screen that said "free" reads as a scam.
  ///
  /// In en, this message translates to:
  /// **'Free for 1 day, then {price}/month. UPI Autopay verifies your account with ₹2, refunded instantly. Browsing stays free forever.'**
  String premiumFootnoteTrial(String price);

  /// Paywall footnote for a user whose trial is consumed — the server charges the full month upfront, so this must say so rather than promise a free day.
  ///
  /// In en, this message translates to:
  /// **'{price} charged today, then renews monthly via UPI Autopay. Cancel anytime. Browsing stays free forever.'**
  String premiumFootnotePaid(String price);

  /// No description provided for @premiumComingSoonToast.
  ///
  /// In en, this message translates to:
  /// **'Premium is coming soon.'**
  String get premiumComingSoonToast;

  /// No description provided for @premiumWelcomeToast.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Arul Premium!'**
  String get premiumWelcomeToast;

  /// No description provided for @premiumCelebrateTitle.
  ///
  /// In en, this message translates to:
  /// **'You\'re in'**
  String get premiumCelebrateTitle;

  /// No description provided for @premiumCelebrateBody.
  ///
  /// In en, this message translates to:
  /// **'Arul Premium is active. Know someone who would love these wallpapers? Send them one.'**
  String get premiumCelebrateBody;

  /// No description provided for @premiumSheetPitch.
  ///
  /// In en, this message translates to:
  /// **'Every wallpaper, live and still. Apply and share freely across all six categories.'**
  String get premiumSheetPitch;

  /// No description provided for @premiumKeepBrowsing.
  ///
  /// In en, this message translates to:
  /// **'Keep browsing free'**
  String get premiumKeepBrowsing;

  /// No description provided for @referTitle.
  ///
  /// In en, this message translates to:
  /// **'Refer & Earn'**
  String get referTitle;

  /// No description provided for @referHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'Gift a friend, earn a month'**
  String get referHeroTitle;

  /// No description provided for @referHeroBody.
  ///
  /// In en, this message translates to:
  /// **'30 days of free premium for every friend who subscribes with your link'**
  String get referHeroBody;

  /// No description provided for @referShareWhatsapp.
  ///
  /// In en, this message translates to:
  /// **'Share via WhatsApp'**
  String get referShareWhatsapp;

  /// No description provided for @referRewardsLabel.
  ///
  /// In en, this message translates to:
  /// **'Rewards earned'**
  String get referRewardsLabel;

  /// Reward total on Refer & Earn, rendered under the "Rewards earned" label. Days of free premium granted, never a currency amount.
  ///
  /// In en, this message translates to:
  /// **'{days} days'**
  String referRewardDays(int days);

  /// No description provided for @referHowItWorks.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get referHowItWorks;

  /// No description provided for @referStep1.
  ///
  /// In en, this message translates to:
  /// **'Share your link with friends and family'**
  String get referStep1;

  /// No description provided for @referStep2.
  ///
  /// In en, this message translates to:
  /// **'They install Arul and subscribe to premium'**
  String get referStep2;

  /// No description provided for @referStep3.
  ///
  /// In en, this message translates to:
  /// **'30 days of free premium lands in your account'**
  String get referStep3;

  /// No description provided for @referEmpty.
  ///
  /// In en, this message translates to:
  /// **'No referrals yet — your first friend is one share away'**
  String get referEmpty;

  /// No description provided for @referShareCta.
  ///
  /// In en, this message translates to:
  /// **'Share Arul'**
  String get referShareCta;

  /// No description provided for @referNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get referNotNow;

  /// No description provided for @uploadScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Upload wallpaper'**
  String get uploadScreenTitle;

  /// No description provided for @uploadPickZoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose an image or video'**
  String get uploadPickZoneTitle;

  /// No description provided for @uploadPickZoneSub.
  ///
  /// In en, this message translates to:
  /// **'Portrait, 1080×2400 or larger'**
  String get uploadPickZoneSub;

  /// No description provided for @uploadTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get uploadTitleLabel;

  /// No description provided for @uploadTitleOptional.
  ///
  /// In en, this message translates to:
  /// **'(optional)'**
  String get uploadTitleOptional;

  /// No description provided for @uploadTitleHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Meenakshi at dusk'**
  String get uploadTitleHint;

  /// No description provided for @uploadCategoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get uploadCategoryLabel;

  /// No description provided for @uploadRightsCheckbox.
  ///
  /// In en, this message translates to:
  /// **'I own the rights to this content or have permission to share it'**
  String get uploadRightsCheckbox;

  /// No description provided for @uploadSubmitCta.
  ///
  /// In en, this message translates to:
  /// **'Submit for review'**
  String get uploadSubmitCta;

  /// No description provided for @uploadFootnote.
  ///
  /// In en, this message translates to:
  /// **'Approved wallpapers appear in the feed with your name'**
  String get uploadFootnote;

  /// No description provided for @uploadRejectStatic.
  ///
  /// In en, this message translates to:
  /// **'Please choose a JPEG, PNG or WebP image.'**
  String get uploadRejectStatic;

  /// No description provided for @uploadRejectLive.
  ///
  /// In en, this message translates to:
  /// **'Please choose an MP4 video.'**
  String get uploadRejectLive;

  /// No description provided for @uploadRejectAudio.
  ///
  /// In en, this message translates to:
  /// **'Please choose an MP3, AAC or M4A audio file.'**
  String get uploadRejectAudio;

  /// No description provided for @uploadKindLabel.
  ///
  /// In en, this message translates to:
  /// **'What are you sharing?'**
  String get uploadKindLabel;

  /// No description provided for @uploadKindWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get uploadKindWallpaper;

  /// No description provided for @uploadKindRingtone.
  ///
  /// In en, this message translates to:
  /// **'Ringtone'**
  String get uploadKindRingtone;

  /// No description provided for @uploadPickZoneTitleAudio.
  ///
  /// In en, this message translates to:
  /// **'Choose an audio file'**
  String get uploadPickZoneTitleAudio;

  /// No description provided for @uploadPickZoneSubAudio.
  ///
  /// In en, this message translates to:
  /// **'MP3, AAC or M4A'**
  String get uploadPickZoneSubAudio;

  /// No description provided for @uploadTitleHintRingtone.
  ///
  /// In en, this message translates to:
  /// **'e.g. Kanda Sasti Kavasam'**
  String get uploadTitleHintRingtone;

  /// No description provided for @uploadFootnoteRingtone.
  ///
  /// In en, this message translates to:
  /// **'Approved ringtones appear in the Ringtones tab with your name'**
  String get uploadFootnoteRingtone;

  /// No description provided for @uploadShareMomentBodyRingtone.
  ///
  /// In en, this message translates to:
  /// **'We\'ll review your ringtone shortly. While you wait — know someone who would enjoy Arul?'**
  String get uploadShareMomentBodyRingtone;

  /// Rejection toast when the picked file exceeds the per-type cap. {max} is already a formatted size ("10MB" / "50MB") from UploadConstraints.maxLabel.
  ///
  /// In en, this message translates to:
  /// **'File is too large (max {max}).'**
  String uploadTooLarge(String max);

  /// No description provided for @uploadSuccessToast.
  ///
  /// In en, this message translates to:
  /// **'Submitted for review — thank you!'**
  String get uploadSuccessToast;

  /// No description provided for @uploadShareMomentTitle.
  ///
  /// In en, this message translates to:
  /// **'Thank you'**
  String get uploadShareMomentTitle;

  /// No description provided for @uploadShareMomentBody.
  ///
  /// In en, this message translates to:
  /// **'We\'ll review your wallpaper shortly. While you wait — know someone who would enjoy Arul?'**
  String get uploadShareMomentBody;

  /// No description provided for @uploadComingSoonToast.
  ///
  /// In en, this message translates to:
  /// **'Upload is coming soon.'**
  String get uploadComingSoonToast;

  /// No description provided for @premiumNavTitle.
  ///
  /// In en, this message translates to:
  /// **'SUBSCRIPTION'**
  String get premiumNavTitle;

  /// No description provided for @premiumEyebrow.
  ///
  /// In en, this message translates to:
  /// **'PREMIUM'**
  String get premiumEyebrow;

  /// No description provided for @premiumTagline.
  ///
  /// In en, this message translates to:
  /// **'Divine grace, every day'**
  String get premiumTagline;

  /// No description provided for @premiumPerMonthCaption.
  ///
  /// In en, this message translates to:
  /// **'PER MONTH'**
  String get premiumPerMonthCaption;

  /// No description provided for @premiumTrialLeadPrefix.
  ///
  /// In en, this message translates to:
  /// **'Start your 1-day FREE trial for '**
  String get premiumTrialLeadPrefix;

  /// No description provided for @premiumRefundedBadge.
  ///
  /// In en, this message translates to:
  /// **'REFUNDED INSTANTLY'**
  String get premiumRefundedBadge;

  /// No description provided for @premiumFeatureWallpapers.
  ///
  /// In en, this message translates to:
  /// **'Unlimited HD Wallpapers'**
  String get premiumFeatureWallpapers;

  /// No description provided for @premiumFeatureRingtones.
  ///
  /// In en, this message translates to:
  /// **'Devotional Ringtones'**
  String get premiumFeatureRingtones;

  /// No description provided for @premiumFeatureDaily.
  ///
  /// In en, this message translates to:
  /// **'Daily New Content'**
  String get premiumFeatureDaily;

  /// No description provided for @premiumCtaTrial.
  ///
  /// In en, this message translates to:
  /// **'Start Free Trial'**
  String get premiumCtaTrial;

  /// No description provided for @premiumCtaSubscribe.
  ///
  /// In en, this message translates to:
  /// **'Subscribe Now'**
  String get premiumCtaSubscribe;

  /// No description provided for @premiumReassuranceTrial.
  ///
  /// In en, this message translates to:
  /// **'₹2 verification, refunded instantly · Cancel anytime'**
  String get premiumReassuranceTrial;

  /// No description provided for @premiumReassurancePaid.
  ///
  /// In en, this message translates to:
  /// **'Secured by UPI Autopay · Cancel anytime in one tap'**
  String get premiumReassurancePaid;

  /// Title of the QR sheet on the free-trial variant.
  ///
  /// In en, this message translates to:
  /// **'Scan to start your free trial'**
  String get premiumQrTitleTrial;

  /// Title of the QR sheet when the trial is already spent and the charge is the full price.
  ///
  /// In en, this message translates to:
  /// **'Scan to subscribe'**
  String get premiumQrTitlePaid;

  /// The one instruction on the QR sheet. 'Another phone' is the point: this phone has no UPI app, which is why the code is here at all.
  ///
  /// In en, this message translates to:
  /// **'Open any UPI app on another phone and scan this code.'**
  String get premiumQrInstruction;

  /// Countdown under the QR. The deadline is PhonePe's own, read out of the link, so it is short — often five minutes.
  ///
  /// In en, this message translates to:
  /// **'Code expires in {time}'**
  String premiumQrExpiresIn(String time);

  /// Status line while the server is being polled. Nobody returns to the app on this path, so this line is all the feedback there is until the mandate settles.
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval…'**
  String get premiumQrWaiting;

  /// Button on the QR sheet for someone who has just approved the mandate on the other phone and does not want to wait for the next poll. It only asks the server sooner; it can never settle anything the poll would not.
  ///
  /// In en, this message translates to:
  /// **'I have paid'**
  String get premiumQrCheck;

  /// The paywall's main button once the user has come back from their UPI app with the mandate still unapproved. It re-opens the SAME mandate link — never a new payment — so it must read as continuing, not as paying twice. {app} is the UPI app's own name from the phone (PhonePe, Google Pay, Paytm), never translated.
  ///
  /// In en, this message translates to:
  /// **'Open {app} again'**
  String premiumResumeCta(String app);

  /// Replaces the reassurance line while a mandate is waiting to be approved, on the free-trial variant. The audience is not payment-literate: say the one thing that has to happen, in the app it has to happen in. ₹2 is the penny-drop the trial mandate charges and refunds.
  ///
  /// In en, this message translates to:
  /// **'Approve the ₹2 verification in {app} to start your trial.'**
  String premiumResumeHintTrial(String app);

  /// The same waiting-for-approval line on the paid variant, where there is no trial and no ₹2 — the first charge is the monthly price.
  ///
  /// In en, this message translates to:
  /// **'Approve the payment in {app} to continue.'**
  String premiumResumeHintPaid(String app);

  /// Stands in for {app} in the resume lines when the app's own name cannot be read from the phone. Must read naturally inside those sentences. ta/te/kn/ml add their own word for 'app' AFTER {app} in those lines, so their value here must NOT end in it — it rendered 'your UPI app app'.
  ///
  /// In en, this message translates to:
  /// **'your UPI app'**
  String get premiumUpiAppGeneric;

  /// No description provided for @trialNudgeRow.
  ///
  /// In en, this message translates to:
  /// **'Finish setting up your free trial'**
  String get trialNudgeRow;

  /// No description provided for @trialNudgeDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get trialNudgeDismiss;

  /// No description provided for @trialReminderTitle.
  ///
  /// In en, this message translates to:
  /// **'Your free trial is waiting'**
  String get trialReminderTitle;

  /// No description provided for @trialReminderBody.
  ///
  /// In en, this message translates to:
  /// **'You didn\'t finish setting up. Tap to try again — it takes a moment.'**
  String get trialReminderBody;

  /// No description provided for @premiumSelectedUpiApp.
  ///
  /// In en, this message translates to:
  /// **'Selected UPI App'**
  String get premiumSelectedUpiApp;

  /// No description provided for @upiPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Pay using'**
  String get upiPickerTitle;

  /// No description provided for @upiPickerLastUsed.
  ///
  /// In en, this message translates to:
  /// **'Last used'**
  String get upiPickerLastUsed;

  /// Last row of the UPI picker, under the installed apps. Opens the same scannable mandate code a phone with no UPI app gets on its CTA. A one-time route, never remembered as the default.
  ///
  /// In en, this message translates to:
  /// **'Pay with QR'**
  String get upiPickerQrTitle;

  /// Second line of the QR row in the UPI picker. The mandate link carries no app binding, so it can be approved on any phone — which is the whole reason this row exists beside the installed apps.
  ///
  /// In en, this message translates to:
  /// **'Scan from another phone'**
  String get upiPickerQrSubtitle;

  /// No description provided for @premiumTrialFinePrint.
  ///
  /// In en, this message translates to:
  /// **'Then {price}/month via autopay. Cancel anytime.'**
  String premiumTrialFinePrint(String price);

  /// The price-card fine print on the PAID paywall variant, under the ₹199 lockup. Same sentence as premiumTrialFinePrint without the "Then" — a trial-consumed user is charged the month up front, so nothing precedes it. A commercial statement: the monthly renewal and the cancel-anytime right must both survive translation.
  ///
  /// In en, this message translates to:
  /// **'{price}/month via autopay. Cancel anytime.'**
  String premiumPaidFinePrint(String price);

  /// No description provided for @premiumSocialProof.
  ///
  /// In en, this message translates to:
  /// **'{name} in {city} just applied a live wallpaper 🙏'**
  String premiumSocialProof(String name, String city);

  /// Android notification channel name for CMS-composed campaign pushes. The only user-visible string this feature has — no screen mentions push.
  ///
  /// In en, this message translates to:
  /// **'Updates from Arul'**
  String get pushChannelName;

  /// Toast on /premium when the checkout could not reach the server after its retries. The one payment failure the user can fix themselves.
  ///
  /// In en, this message translates to:
  /// **'No internet. Check your connection and try again.'**
  String get purchaseErrorNetwork;

  /// Toast on /premium for a checkout failure with no more specific line.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get purchaseErrorGeneric;

  /// Neutral toast on /premium when the user backed out of the PhonePe payment page themselves.
  ///
  /// In en, this message translates to:
  /// **'Payment cancelled.'**
  String get purchaseCancelled;

  /// Toast on /premium when the PhonePe payment page was interrupted before finishing.
  ///
  /// In en, this message translates to:
  /// **'Payment was interrupted. Please try again.'**
  String get purchaseInterrupted;

  /// Toast on /premium when the PhonePe payment page ended without a completed payment.
  ///
  /// In en, this message translates to:
  /// **'Payment was not completed. Please try again.'**
  String get purchaseNotCompleted;

  /// Toast on /premium when another payment setup by the same user is still running on the server.
  ///
  /// In en, this message translates to:
  /// **'A payment setup is already in progress. Please wait a few seconds and try again.'**
  String get purchaseInProgress;

  /// Toast on /premium when the chosen UPI app could not be opened.
  ///
  /// In en, this message translates to:
  /// **'Could not open your UPI app. Please try again.'**
  String get purchaseUpiLaunchFailed;

  /// The ONE failure line the UPI-app flow shows. A commercial statement: the refund hedge is conditional ('any amount deducted') and the 4–5 days must survive translation.
  ///
  /// In en, this message translates to:
  /// **'Payment failed. Any amount deducted will be refunded to your account within 4–5 days.'**
  String get purchaseIntentFailed;

  /// Toast on /premium when the server reports a terminal state it cannot activate from.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t activate your subscription. Please contact support.'**
  String get purchaseActivateFailed;

  /// Toast on /premium when the payment may have gone through but the server has not confirmed it yet. A commercial statement.
  ///
  /// In en, this message translates to:
  /// **'Payment received but confirmation is delayed. Please restart the app — your subscription will activate shortly.'**
  String get purchaseConfirmationLate;

  /// Sign-in wall toast: Google Play services cannot run the sign-in (AuthFailureKind.noPlayServices).
  ///
  /// In en, this message translates to:
  /// **'Google Play Services is unavailable. Please update or reinstall.'**
  String get authErrorNoPlayServices;

  /// Sign-in wall toast: the link died during sign-in (AuthFailureKind.networkError). Same words as purchaseErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'No internet. Check your connection and try again.'**
  String get authErrorNetwork;

  /// Sign-in wall toast: Google returned no usable token (AuthFailureKind.tokenExchangeFailed).
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed. Please try again.'**
  String get authErrorTokenExchange;

  /// Sign-in wall toast: our server refused the login (AuthFailureKind.serverError). Never the server's own message.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed. Please try again.'**
  String get authErrorServer;

  /// Sign-in wall toast: Google's flow ended without a result (AuthFailureKind.unknown); in the field this is mostly a dead link.
  ///
  /// In en, this message translates to:
  /// **'Sign-in didn\'t complete. Check your internet connection and try again.'**
  String get authErrorIncomplete;

  /// Splash line under the wordmark. Latin renders in tracked caps; 'bhakti' is kept as one word in every script.
  ///
  /// In en, this message translates to:
  /// **'Bhakti in your hands'**
  String get splashTagline;

  /// Screen-reader label for the paywall clip's sound button while sound is on.
  ///
  /// In en, this message translates to:
  /// **'Mute video'**
  String get videoMute;

  /// Screen-reader label for the paywall clip's sound button while muted.
  ///
  /// In en, this message translates to:
  /// **'Unmute video'**
  String get videoUnmute;

  /// Plan screen headline for an active paying member.
  ///
  /// In en, this message translates to:
  /// **'You\'re a member'**
  String get premiumMemberHeadline;

  /// Plan screen subline during the free trial.
  ///
  /// In en, this message translates to:
  /// **'Full access to every wallpaper. Your first {price} payment is charged when the trial ends.'**
  String premiumMemberTrialSubline(String price);

  /// Plan screen subline for an active member.
  ///
  /// In en, this message translates to:
  /// **'Every wallpaper, still and live, is yours to apply and share.'**
  String get premiumMemberSubline;

  /// Billing row label; the value is a date.
  ///
  /// In en, this message translates to:
  /// **'Trial ends'**
  String get premiumTrialEndsLabel;

  /// Billing row label; the value is a date.
  ///
  /// In en, this message translates to:
  /// **'Renews on'**
  String get premiumRenewsOnLabel;

  /// Plan screen fine print during the trial.
  ///
  /// In en, this message translates to:
  /// **'Cancel before the trial ends and you are never charged. Billed monthly via UPI Autopay.'**
  String get premiumMemberTrialFootnote;

  /// Plan screen fine print for an active member.
  ///
  /// In en, this message translates to:
  /// **'Billed monthly via UPI Autopay. Cancel anytime — your access continues until the current period ends.'**
  String get premiumMemberFootnote;

  /// Status chip (rendered in caps in Latin).
  ///
  /// In en, this message translates to:
  /// **'Free trial'**
  String get premiumStatusTrial;

  /// Status chip (rendered in caps in Latin).
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get premiumStatusActive;

  /// Billing row label.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get premiumPlanLabel;

  /// Billing row value: the plan period.
  ///
  /// In en, this message translates to:
  /// **'Monthly'**
  String get premiumPlanMonthly;

  /// Billing row label.
  ///
  /// In en, this message translates to:
  /// **'Payment'**
  String get premiumPaymentLabel;

  /// Billing row value: the payment method. Same transliteration as premiumPlanNote.
  ///
  /// In en, this message translates to:
  /// **'UPI Autopay'**
  String get premiumPaymentUpiAutopay;

  /// Plan screen reassurance line.
  ///
  /// In en, this message translates to:
  /// **'We\'ll remind you 24 hours before every renewal.'**
  String get premiumRenewalReminder;

  /// Plan screen button.
  ///
  /// In en, this message translates to:
  /// **'Cancel subscription'**
  String get premiumCancelSubscription;

  /// Cancelled-but-paid-through headline. Same words as settingsPremiumSubCancelled.
  ///
  /// In en, this message translates to:
  /// **'Auto-renew is off'**
  String get premiumAutoRenewOffHeadline;

  /// Cancelled-but-paid-through subline.
  ///
  /// In en, this message translates to:
  /// **'You keep full access until your paid period ends. You won\'t be charged again.'**
  String get premiumAutoRenewOffSubline;

  /// Status chip (rendered in caps in Latin).
  ///
  /// In en, this message translates to:
  /// **'Auto-renew off'**
  String get premiumStatusAutoRenewOff;

  /// Billing row label; the value is a date.
  ///
  /// In en, this message translates to:
  /// **'Access until'**
  String get premiumAccessUntilLabel;

  /// Button on the cancelled plan screen.
  ///
  /// In en, this message translates to:
  /// **'Resubscribe'**
  String get premiumResubscribeCta;

  /// Fine print under Resubscribe.
  ///
  /// In en, this message translates to:
  /// **'Resubscribing sets up a fresh UPI Autopay mandate at {price} a month.'**
  String premiumResubscribeFootnote(String price);

  /// Link beside the chosen UPI app.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get premiumChange;

  /// Cancel confirmation dialog title.
  ///
  /// In en, this message translates to:
  /// **'Cancel subscription?'**
  String get premiumCancelDialogTitle;

  /// Cancel dialog body when the period end is unknown.
  ///
  /// In en, this message translates to:
  /// **'Your premium access stays active until the end of the current billing period. After that you won\'t be charged again.'**
  String get premiumCancelDialogBody;

  /// Cancel dialog body with the period end.
  ///
  /// In en, this message translates to:
  /// **'Your premium access stays active until {date}. After that you won\'t be charged again.'**
  String premiumCancelDialogBodyDate(DateTime date);

  /// Cancel dialog confirm button.
  ///
  /// In en, this message translates to:
  /// **'Cancel it'**
  String get premiumCancelConfirm;

  /// Toast after a successful cancel, period end unknown.
  ///
  /// In en, this message translates to:
  /// **'Subscription cancelled. You keep premium until the period ends.'**
  String get premiumCancelledToast;

  /// Toast after a successful cancel, with the period end.
  ///
  /// In en, this message translates to:
  /// **'Subscription cancelled. You keep premium until {date}.'**
  String premiumCancelledToastDate(DateTime date);

  /// A plan date in the app's language (month name localized by intl).
  ///
  /// In en, this message translates to:
  /// **'{date}'**
  String premiumPlanDate(DateTime date);

  /// Cancel-subscription dialog: the way OUT (keeps the plan). Must not say 'cancel' — the other button does.
  ///
  /// In en, this message translates to:
  /// **'Keep premium'**
  String get premiumCancelKeep;
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
