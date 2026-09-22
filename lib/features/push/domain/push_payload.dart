/// What a campaign notification's `data` map asked the app to open.
///
/// Pure, and the whole reason it is pure: this is the one piece of the tap path that can be tested
/// without a device, a plugin or a live campaign. Everything downstream of it is routing.
///
/// **Every unreadable payload resolves to HOME.** A campaign composed against a newer app, a
/// destination this build has never heard of, a wallpaper deleted since the send, a category
/// retired last week — all of them open the app. A tap must never produce an error screen or a
/// crash: the person tapped a notification we sent them, and landing somewhere is the floor.
library;

import '../../../core/deeplink/deep_link_target.dart';

/// The destination keys the Worker writes into `data.dest`. Anything else is treated as home.
const _kDestWallpaper = 'wallpaper';
const _kDestRingtone = 'ringtone';
const _kDestCategory = 'category';
const _kDestPremium = 'premium';

/// Content ids are always uuids — anything else is a malformed payload, never a lookup.
final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// The campaign this notification belongs to, or null when the payload does not name one.
/// Only a well-formed id is reported back to the Worker — a junk value would just be a 400.
String? pushCampaignId(Map<String, Object?> data) {
  final raw = data['campaign_id'];
  if (raw is! String) return null;
  final id = raw.trim();
  return _uuidRe.hasMatch(id) ? id : null;
}

/// The target a campaign payload names, or null for "just open the app".
///
/// `id` is required for the two content destinations and IGNORED for the rest: a category push whose
/// slug went missing still belongs on the feed, and the premium screen never had an id.
DeepLinkTarget? pushTargetFor(Map<String, Object?> data) {
  // Read, never cast. FCM requires string data values, so a non-string can only come from a payload
  // nobody here composed — and a cast that throws would be an unreadable payload turning into a
  // crash, which is precisely what this function exists to prevent.
  final dest = _str(data['dest']).trim().toLowerCase();
  final id = _str(data['id']).trim();

  switch (dest) {
    case _kDestWallpaper:
      return _uuidRe.hasMatch(id)
          ? WallpaperLinkTarget(id.toLowerCase(), source: DeepLinkSource.push)
          : null;
    case _kDestRingtone:
      return _uuidRe.hasMatch(id)
          ? RingtoneLinkTarget(id.toLowerCase(), source: DeepLinkSource.push)
          : null;
    case _kDestCategory:
      // A slug, not a uuid. An empty one is a composer bug, not a category — fall through to home.
      return id.isEmpty
          ? null
          : CategoryLinkTarget(id.toLowerCase(), source: DeepLinkSource.push);
    case _kDestPremium:
      return const PremiumLinkTarget(source: DeepLinkSource.push);
    default:
      return null;
  }
}

/// The language the Worker picked for this phone, for the `push_opened` diagnostic. Never routing.
String? pushLang(Map<String, Object?> data) {
  final raw = data['lang'];
  return raw is String && raw.isNotEmpty ? raw : null;
}

/// A payload value as a string, or empty. See the note in [pushTargetFor]: read, never cast.
String _str(Object? value) => value is String ? value : '';
