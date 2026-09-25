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
  String get categoryAll => 'All';

  @override
  String get categoryNew => 'New';

  @override
  String get feedLiveBadge => 'Live';

  @override
  String get feedEmptyTitle => 'Nothing here yet';

  @override
  String get feedEmptyBody => 'Try another category.';

  @override
  String get feedBrowseAll => 'Browse all';

  @override
  String get feedLoadingBody => 'Bringing your wallpapers…';

  @override
  String get feedErrorTitle => 'Couldn\'t load wallpapers';

  @override
  String get feedErrorBody => 'Check your connection and try again.';

  @override
  String get retry => 'Retry';

  @override
  String get errorGeneric => 'Something went wrong.';

  @override
  String get signInCaption => 'Bring the divine home';

  @override
  String get signInGoogle => 'Continue with Google';

  @override
  String get signInSubtitleIdle => 'Choose an account to start';

  @override
  String get signInSubtitleExchanging => 'Signing you in…';

  @override
  String get signInNudgeRetry => 'Click here to sign in';

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
  String get applyTargetBoth => 'Both';

  @override
  String get applied => 'Wallpaper applied';

  @override
  String get appliedLiveFallback =>
      'Live wallpapers aren\'t supported on this phone, so we set a still image instead.';

  @override
  String get offlineBody =>
      'You\'re offline. Check your connection and try again.';

  @override
  String get offlineTitle => 'No internet';

  @override
  String get offlineFeedBody => 'Turn on the internet to see wallpapers.';

  @override
  String wallpaperShareCaption(String link) {
    return 'More devotional wallpapers like this one — still and live — on Arul:\n$link';
  }

  @override
  String referShareMessage(String link) {
    return 'I\'ve been using Arul for South Indian devotional wallpapers — Amman, Murugan, Perumal, Sivan, and live ones that actually move. Thought you\'d like it.\n\n$link';
  }

  @override
  String get tabWallpapers => 'Wallpapers';

  @override
  String get tabRingtones => 'Ringtones';

  @override
  String get earn => 'Earn';

  @override
  String get ringtoneSet => 'Set';

  @override
  String get ringtonePreviewSemantic => 'Preview';

  @override
  String get ringtonePreviewUnavailable => 'Preview not available yet';

  @override
  String get ringtoneVolumeMuted => 'Turn up the volume to hear this preview';

  @override
  String get ringtoneCurrentBadge => 'Current';

  @override
  String get ringtonesEmptyTitle => 'Ringtones are coming soon';

  @override
  String get ringtonesEmptyBody =>
      'Devotional ringtones are on their way. Check back soon.';

  @override
  String get ringtonesErrorTitle => 'Couldn\'t load ringtones';

  @override
  String get ringtoneSetSuccess =>
      'Ringtone set. If it doesn\'t appear, restart your phone.';

  @override
  String get ringtoneSetFailed =>
      'Couldn\'t set the ringtone. Please try again.';

  @override
  String get ringtoneSetPreparing => 'Preparing…';

  @override
  String get ringtoneSetDownloading => 'Downloading…';

  @override
  String get ringtoneSetApplying => 'Setting ringtone…';

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get errorGenericRetry => 'Something went wrong. Please try again.';

  @override
  String get settingsFallbackName => 'Your account';

  @override
  String get settingsFallbackEmail => 'Signed in with Google';

  @override
  String get settingsPremiumSubTrial => 'You\'re on the free trial';

  @override
  String get settingsPremiumSubCancelled => 'Auto-renew off · access continues';

  @override
  String get settingsPremiumSubActive => 'You\'re a member';

  @override
  String get settingsReferSub => 'Earn 30 days free premium';

  @override
  String get settingsTellFriend => 'Tell a friend';

  @override
  String get settingsTellFriendSub => 'Send Arul to someone who would love it';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsNeedHelp => 'Need help?';

  @override
  String get settingsNeedHelpSub => 'Support and subscription';

  @override
  String get settingsHelpSupport => 'Contact support';

  @override
  String get settingsHelpSupportSub => 'Write to us by email';

  @override
  String get settingsHelpManage => 'Manage subscription';

  @override
  String get settingsHelpDeleteSub => 'Remove your account';

  @override
  String get settingsUpload => 'Upload your content';

  @override
  String get settingsUploadSub => 'Share a wallpaper or ringtone';

  @override
  String get settingsLogout => 'Logout';

  @override
  String get settingsLogoutConfirmTitle => 'Logout?';

  @override
  String get settingsLogoutConfirmBody =>
      'You can sign back in anytime with Google.';

  @override
  String get settingsDeleteAccount => 'Delete account';

  @override
  String get settingsDeleteConfirmTitle => 'Delete account?';

  @override
  String get settingsDeleteConfirmBody => 'This can\'t be undone.';

  @override
  String get settingsDeleteConfirmBodyPremium =>
      'Premium ends now. The days left aren\'t refunded, and a new account won\'t get a free trial.';

  @override
  String get settingsTerms => 'Terms & Conditions';

  @override
  String get settingsRefund => 'Refund policy';

  @override
  String get settingsSupportEmailPrompt =>
      'Please describe your issue or feedback:';

  @override
  String get settingsSupportEmailDetails =>
      'The details below help us resolve your request faster:';

  @override
  String settingsNoEmailApp(String email) {
    return 'No email app found. Write to us at $email';
  }

  @override
  String get settingsEditNameTitle => 'Your name';

  @override
  String get settingsEditNameSub => 'Shown on wallpapers you upload';

  @override
  String get themeSystemDefault => 'System default';

  @override
  String get themeSystemSub => 'Follow device setting';

  @override
  String get themeLightSub => 'Ivory & silk';

  @override
  String get themeDarkSub => 'Lamp-lit maroon';

  @override
  String get remindersTimeLabel => 'Reminder time';

  @override
  String get premiumScreenSubline =>
      'The full collection, alive on your screen';

  @override
  String get premiumPerkEvery => 'Every wallpaper, still and live';

  @override
  String get premiumPerkApplyShare => 'Apply and share without limits';

  @override
  String get premiumPerkNew => 'New arrivals every week';

  @override
  String get premiumPerMonth => '/ month';

  @override
  String get premiumPlanNote => 'UPI Autopay · cancel anytime';

  @override
  String get premiumTrialPill => '1 DAY FREE';

  @override
  String get premiumCtaPaid => 'Get Premium';

  @override
  String premiumFootnoteTrial(String price) {
    return 'Free for 1 day, then $price/month. UPI Autopay verifies your account with ₹2, refunded instantly. Browsing stays free forever.';
  }

  @override
  String premiumFootnotePaid(String price) {
    return '$price charged today, then renews monthly via UPI Autopay. Cancel anytime. Browsing stays free forever.';
  }

  @override
  String get premiumComingSoonToast => 'Premium is coming soon.';

  @override
  String get premiumWelcomeToast => 'Welcome to Arul Premium!';

  @override
  String get premiumCelebrateTitle => 'You\'re in';

  @override
  String get premiumCelebrateBody =>
      'Arul Premium is active. Know someone who would love these wallpapers? Send them one.';

  @override
  String get premiumSheetPitch =>
      'Every wallpaper, live and still. Apply and share freely across all six categories.';

  @override
  String get premiumKeepBrowsing => 'Keep browsing free';

  @override
  String get referTitle => 'Refer & Earn';

  @override
  String get referHeroTitle => 'Gift a friend, earn a month';

  @override
  String get referHeroBody =>
      '30 days of free premium for every friend who subscribes with your link';

  @override
  String get referShareWhatsapp => 'Share via WhatsApp';

  @override
  String get referRewardsLabel => 'Rewards earned';

  @override
  String referRewardDays(int days) {
    return '$days days';
  }

  @override
  String get referHowItWorks => 'How it works';

  @override
  String get referStep1 => 'Share your link with friends and family';

  @override
  String get referStep2 => 'They install Arul and subscribe to premium';

  @override
  String get referStep3 => '30 days of free premium lands in your account';

  @override
  String get referEmpty =>
      'No referrals yet — your first friend is one share away';

  @override
  String get referShareCta => 'Share Arul';

  @override
  String get referNotNow => 'Not now';

  @override
  String get uploadScreenTitle => 'Upload wallpaper';

  @override
  String get uploadPickZoneTitle => 'Choose an image or video';

  @override
  String get uploadPickZoneSub => 'Portrait, 1080×2400 or larger';

  @override
  String get uploadTitleLabel => 'Title';

  @override
  String get uploadTitleOptional => '(optional)';

  @override
  String get uploadTitleHint => 'e.g. Meenakshi at dusk';

  @override
  String get uploadCategoryLabel => 'Category';

  @override
  String get uploadRightsCheckbox =>
      'I own the rights to this content or have permission to share it';

  @override
  String get uploadSubmitCta => 'Submit for review';

  @override
  String get uploadFootnote =>
      'Approved wallpapers appear in the feed with your name';

  @override
  String get uploadRejectStatic => 'Please choose a JPEG, PNG or WebP image.';

  @override
  String get uploadRejectLive => 'Please choose an MP4 video.';

  @override
  String get uploadRejectAudio =>
      'Please choose an MP3, AAC or M4A audio file.';

  @override
  String get uploadKindLabel => 'What are you sharing?';

  @override
  String get uploadKindWallpaper => 'Wallpaper';

  @override
  String get uploadKindRingtone => 'Ringtone';

  @override
  String get uploadPickZoneTitleAudio => 'Choose an audio file';

  @override
  String get uploadPickZoneSubAudio => 'MP3, AAC or M4A';

  @override
  String get uploadTitleHintRingtone => 'e.g. Kanda Sasti Kavasam';

  @override
  String get uploadFootnoteRingtone =>
      'Approved ringtones appear in the Ringtones tab with your name';

  @override
  String get uploadShareMomentBodyRingtone =>
      'We\'ll review your ringtone shortly. While you wait — know someone who would enjoy Arul?';

  @override
  String uploadTooLarge(String max) {
    return 'File is too large (max $max).';
  }

  @override
  String get uploadSuccessToast => 'Submitted for review — thank you!';

  @override
  String get uploadShareMomentTitle => 'Thank you';

  @override
  String get uploadShareMomentBody =>
      'We\'ll review your wallpaper shortly. While you wait — know someone who would enjoy Arul?';

  @override
  String get uploadComingSoonToast => 'Upload is coming soon.';

  @override
  String get premiumNavTitle => 'SUBSCRIPTION';

  @override
  String get premiumEyebrow => 'PREMIUM';

  @override
  String get premiumTagline => 'Divine grace, every day';

  @override
  String get premiumPerMonthCaption => 'PER MONTH';

  @override
  String get premiumTrialLeadPrefix => 'Start your 1-day FREE trial for ';

  @override
  String get premiumRefundedBadge => 'REFUNDED INSTANTLY';

  @override
  String get premiumFeatureWallpapers => 'Unlimited HD Wallpapers';

  @override
  String get premiumFeatureRingtones => 'Devotional Ringtones';

  @override
  String get premiumFeatureDaily => 'Daily New Content';

  @override
  String get premiumCtaTrial => 'Start Free Trial';

  @override
  String get premiumCtaSubscribe => 'Subscribe Now';

  @override
  String get premiumReassuranceTrial =>
      '₹2 verification, refunded instantly · Cancel anytime';

  @override
  String get premiumReassurancePaid =>
      'Secured by UPI Autopay · Cancel anytime in one tap';

  @override
  String get premiumQrTitleTrial => 'Scan to start your free trial';

  @override
  String get premiumQrTitlePaid => 'Scan to subscribe';

  @override
  String get premiumQrInstruction =>
      'Open any UPI app on another phone and scan this code.';

  @override
  String premiumQrExpiresIn(String time) {
    return 'Code expires in $time';
  }

  @override
  String get premiumQrWaiting => 'Waiting for approval…';

  @override
  String get premiumQrCheck => 'I have paid';

  @override
  String premiumResumeCta(String app) {
    return 'Open $app again';
  }

  @override
  String premiumResumeHintTrial(String app) {
    return 'Approve the ₹2 verification in $app to start your trial.';
  }

  @override
  String premiumResumeHintPaid(String app) {
    return 'Approve the payment in $app to continue.';
  }

  @override
  String get premiumUpiAppGeneric => 'your UPI app';

  @override
  String get trialNudgeRow => 'Finish setting up your free trial';

  @override
  String get trialNudgeDismiss => 'Dismiss';

  @override
  String get trialReminderTitle => 'Your free trial is waiting';

  @override
  String get trialReminderBody =>
      'You didn\'t finish setting up. Tap to try again — it takes a moment.';

  @override
  String get comeBackTitle => 'Your wallpaper is ready';

  @override
  String get comeBackBody => 'One tap to sign in and set it.';

  @override
  String get premiumSelectedUpiApp => 'Selected UPI App';

  @override
  String get upiPickerTitle => 'Pay using';

  @override
  String get upiPickerLastUsed => 'Last used';

  @override
  String get upiPickerQrTitle => 'Pay with QR';

  @override
  String get upiPickerQrSubtitle => 'Scan from another phone';

  @override
  String premiumTrialFinePrint(String price) {
    return 'Then $price/month via autopay. Cancel anytime.';
  }

  @override
  String premiumPaidFinePrint(String price) {
    return '$price/month via autopay. Cancel anytime.';
  }

  @override
  String premiumSocialProof(String name, String city) {
    return '$name in $city just applied a live wallpaper 🙏';
  }

  @override
  String get pushChannelName => 'Updates from Arul';

  @override
  String get purchaseErrorNetwork =>
      'No internet. Check your connection and try again.';

  @override
  String get purchaseErrorGeneric => 'Something went wrong. Please try again.';

  @override
  String get purchaseCancelled => 'Payment cancelled.';

  @override
  String get purchaseInterrupted =>
      'Payment was interrupted. Please try again.';

  @override
  String get purchaseNotCompleted =>
      'Payment was not completed. Please try again.';

  @override
  String get purchaseInProgress =>
      'A payment setup is already in progress. Please wait a few seconds and try again.';

  @override
  String get purchaseUpiLaunchFailed =>
      'Could not open your UPI app. Please try again.';

  @override
  String get purchaseIntentFailed =>
      'Payment failed. Any amount deducted will be refunded to your account within 4–5 days.';

  @override
  String get purchaseActivateFailed =>
      'We couldn\'t activate your subscription. Please contact support.';

  @override
  String get purchaseConfirmationLate =>
      'Payment received but confirmation is delayed. Please restart the app — your subscription will activate shortly.';

  @override
  String get authErrorNoPlayServices =>
      'Google Play Services is unavailable. Please update or reinstall.';

  @override
  String get authErrorNetwork =>
      'No internet. Check your connection and try again.';

  @override
  String get authErrorTokenExchange => 'Sign-in failed. Please try again.';

  @override
  String get authErrorServer => 'Sign-in failed. Please try again.';

  @override
  String get authErrorIncomplete =>
      'Sign-in didn\'t complete. Check your internet connection and try again.';

  @override
  String get splashTagline => 'Bhakti in your hands';

  @override
  String get videoMute => 'Mute video';

  @override
  String get videoUnmute => 'Unmute video';

  @override
  String get premiumMemberHeadline => 'You\'re a member';

  @override
  String premiumMemberTrialSubline(String price) {
    return 'Full access to every wallpaper. Your first $price payment is charged when the trial ends.';
  }

  @override
  String get premiumMemberSubline =>
      'Every wallpaper, still and live, is yours to apply and share.';

  @override
  String get premiumTrialEndsLabel => 'Trial ends';

  @override
  String get premiumRenewsOnLabel => 'Renews on';

  @override
  String get premiumMemberTrialFootnote =>
      'Cancel before the trial ends and you are never charged. Billed monthly via UPI Autopay.';

  @override
  String get premiumMemberFootnote =>
      'Billed monthly via UPI Autopay. Cancel anytime — your access continues until the current period ends.';

  @override
  String get premiumStatusTrial => 'Free trial';

  @override
  String get premiumStatusActive => 'Active';

  @override
  String get premiumPlanLabel => 'Plan';

  @override
  String get premiumPlanMonthly => 'Monthly';

  @override
  String get premiumPaymentLabel => 'Payment';

  @override
  String get premiumPaymentUpiAutopay => 'UPI Autopay';

  @override
  String get premiumRenewalReminder =>
      'We\'ll remind you 24 hours before every renewal.';

  @override
  String get premiumCancelSubscription => 'Cancel subscription';

  @override
  String get premiumAutoRenewOffHeadline => 'Auto-renew is off';

  @override
  String get premiumAutoRenewOffSubline =>
      'You keep full access until your paid period ends. You won\'t be charged again.';

  @override
  String get premiumStatusAutoRenewOff => 'Auto-renew off';

  @override
  String get premiumAccessUntilLabel => 'Access until';

  @override
  String get premiumResubscribeCta => 'Resubscribe';

  @override
  String premiumResubscribeFootnote(String price) {
    return 'Resubscribing sets up a fresh UPI Autopay mandate at $price a month.';
  }

  @override
  String get premiumChange => 'Change';

  @override
  String get premiumCancelDialogTitle => 'Cancel subscription?';

  @override
  String get premiumCancelDialogBody =>
      'Your premium access stays active until the end of the current billing period. After that you won\'t be charged again.';

  @override
  String premiumCancelDialogBodyDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat(
      'd MMM y',
      localeName,
    );
    final String dateString = dateDateFormat.format(date);

    return 'Your premium access stays active until $dateString. After that you won\'t be charged again.';
  }

  @override
  String get premiumCancelConfirm => 'Cancel it';

  @override
  String get premiumCancelledToast =>
      'Subscription cancelled. You keep premium until the period ends.';

  @override
  String premiumCancelledToastDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat(
      'd MMM y',
      localeName,
    );
    final String dateString = dateDateFormat.format(date);

    return 'Subscription cancelled. You keep premium until $dateString.';
  }

  @override
  String premiumPlanDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat(
      'd MMM y',
      localeName,
    );
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String get premiumCancelKeep => 'Keep premium';
}
