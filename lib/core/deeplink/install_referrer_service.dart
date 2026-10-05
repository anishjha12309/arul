import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/shared_preferences_provider.dart';
import 'deep_link_parser.dart';
import 'deep_link_target.dart';

export 'deep_link_parser.dart' show kDeepLinkHost;

part 'install_referrer_service.g.dart';

const String kPlayPackageId = 'com.hsrutility.arul';

@Riverpod(keepAlive: true)
InstallReferrerService installReferrerService(Ref ref) =>
    InstallReferrerService(ref.watch(sharedPreferencesProvider));

/// Captures the Play Install Referrer ONCE per install: the install's attribution and any deferred target.
/// Also the ONE durable home for every deferred deep-link target, whichever path delivered it.
/// Android-only, and a no-op without Play Services -> a missing referrer never affects launch.
class InstallReferrerService {
  InstallReferrerService(
    this._prefs, {
    Future<Map<Object?, Object?>?> Function()? metaReferrer,
  }) : _metaReferrer = metaReferrer ?? _readMetaReferrer;

  final SharedPreferences _prefs;
  final Future<Map<Object?, Object?>?> Function() _metaReferrer;

  static const _deferredLinkChannel = MethodChannel(
    'com.hsrutility.arul/deferred_link',
  );

  /// Meta's last ad touch for this app, from the Facebook/Instagram/Lite apps
  /// (`MetaInstallReferrer.kt`); null when none, or off Android.
  static Future<Map<Object?, Object?>?> _readMetaReferrer() async {
    try {
      return await _deferredLinkChannel.invokeMapMethod<Object?, Object?>(
        'getMetaInstallReferrer',
      );
    } catch (e) {
      debugPrint('[InstallReferrer] Meta referrer unavailable (non-fatal): $e');
      return null;
    }
  }

  // Left by builds that sent a referral code at sign-in -> removed on launch, never read.
  static const _kLegacyPendingCode = 'pending_referral_code';
  static const _kPendingWallpaper = 'pending_deeplink_wallpaper';
  static const _kPendingRingtone = 'pending_deeplink_ringtone';
  static const _kPendingStatus = 'pending_deeplink_status';
  static const _kPendingSource = 'pending_deeplink_source';
  static const _kPendingLang = 'pending_deeplink_lang';
  static const _kChecked = 'install_referrer_checked';
  static const _kInstallChannel = 'install_channel';
  static const _kInstallSource = 'install_utm_source';
  static const _kInstallCampaign = 'install_utm_campaign';
  static const _kInstallLink = 'install_link_kind';
  static const _kClickToInstallS = 'click_to_install_s';
  static const _kInstallToOpenS = 'install_to_open_s';

  /// The ONE link a wallpaper share or ad creative carries — an App Link on [kDeepLinkHost].
  /// Optionally asking for a UI language via [lang].
  /// [installLang] is the SHARE form of [lang]: the sharer's UI language, honoured on a fresh install.
  static String buildWallpaperLink(
    String wallpaperId, {
    String? lang,
    String? installLang,
  }) => _buildLink('w', wallpaperId, lang: lang, installLang: installLang);

  /// The ringtone form of [buildWallpaperLink] — `/r/<id>`. Nothing in the app shares a ringtone.
  /// It exists so ad creatives are built from ONE place and never by hand.
  static String buildRingtoneLink(
    String ringtoneId, {
    String? lang,
    String? installLang,
  }) => _buildLink('r', ringtoneId, lang: lang, installLang: installLang);

  /// The status form — `/s/<id>`, the one link a status shared into a chat carries.
  static String buildStatusLink(
    String statusId, {
    String? lang,
    String? installLang,
  }) => _buildLink('s', statusId, lang: lang, installLang: installLang);

  static String _buildLink(
    String segment,
    String id, {
    String? lang,
    String? installLang,
  }) {
    final query = <String>[
      if (lang != null && lang.isNotEmpty) 'lang=$lang',
      // `lang` already says it louder; never emit both.
      if ((lang == null || lang.isEmpty) &&
          installLang != null &&
          installLang.isNotEmpty)
        'ilang=$installLang',
    ];
    final suffix = query.isEmpty ? '' : '?${query.join('&')}';
    return 'https://$kDeepLinkHost/$segment/$id$suffix';
  }

  /// Where this install came from, read off the Play referrer ONCE and stamped on every sign-in
  /// event — the split PostHog could not make on its own ("is the Tamil Nadu gap the ad audience?").
  @visibleForTesting
  static Map<String, String> parseAttribution(String raw) {
    Map<String, String> params;
    try {
      params = Uri.splitQueryString(raw.trim());
    } catch (_) {
      return const {};
    }
    String? clip(String? v, int max) {
      final t = v?.trim().toLowerCase();
      if (t == null || t.isEmpty) return null;
      return t.length <= max ? t : t.substring(0, max);
    }

    final source = clip(params['utm_source'], 40);
    final medium = clip(params['utm_medium'], 40);
    final campaign = clip(params['utm_campaign'], 60);
    final String channel;
    if (params.containsKey('gclid') ||
        source == 'google' ||
        source == 'google_ads' ||
        source == 'adwords' ||
        medium == 'cpc') {
      channel = 'google_ads';
    } else if (source != null &&
        (source.contains('facebook') ||
            source.contains('instagram') ||
            source.contains('meta') ||
            source == 'fb' ||
            source == 'ig')) {
      channel = 'meta_ads';
    } else if (source == 'google-play' && medium == 'organic') {
      channel = 'organic';
    } else if (_carriesRef(params)) {
      channel = 'share';
    } else if (params.containsKey('w') ||
        params.containsKey('r') ||
        params.containsKey('s') ||
        params.containsKey('screen')) {
      channel = 'link';
    } else if (source != null) {
      channel = 'other';
    } else {
      channel = 'unknown';
    }
    return {
      _kInstallChannel: channel,
      _kInstallSource: ?source,
      _kInstallCampaign: ?campaign,
    };
  }

  /// What Play's referrer left unattributed — Meta's referrer may still name it.
  static bool _unattributed(Map<String, String> play) {
    final channel = play[_kInstallChannel];
    return channel == null ||
        channel == 'organic' ||
        channel == 'unknown' ||
        channel == 'other';
  }

  /// Play's referrer carries only same-session clicks, so a Meta view-through or later-session
  /// click reads `organic`; Meta documents its own referrer as the answer for exactly those.
  /// Anything Play attributed (an ad, a share, one of our links) is never overridden.
  @visibleForTesting
  static Map<String, String> withMetaReferrer(
    Map<String, String> play,
    Map<Object?, Object?>? meta,
  ) {
    if (meta == null || !_unattributed(play)) return play;
    final raw = meta['utm_source'];
    final source = raw is String ? raw.trim().toLowerCase() : '';
    return {
      ...play,
      _kInstallChannel: 'meta_ads',
      if (source.isNotEmpty)
        _kInstallSource: source.length <= 40 ? source : source.substring(0, 40),
    };
  }

  /// The persisted attribution as event properties; empty until the referrer has landed.
  Map<String, Object> get attributionProps {
    final link = _nonEmpty(_prefs.getString(_kInstallLink));
    final channel =
        _nonEmpty(_prefs.getString(_kInstallChannel)) ??
        (link == null ? null : 'unknown');
    return {
      _kInstallChannel: ?(link == null ? channel : '$channel+$link'),
      _kInstallSource: ?_nonEmpty(_prefs.getString(_kInstallSource)),
      _kInstallCampaign: ?_nonEmpty(_prefs.getString(_kInstallCampaign)),
      _kClickToInstallS: ?_prefs.getInt(_kClickToInstallS),
      _kInstallToOpenS: ?_prefs.getInt(_kInstallToOpenS),
    };
  }

  /// Play's own clocks: ad click to install start (0 = no click on record, so not stored), and
  /// install start to this first open — a long gap is an install nobody meant to open yet.
  Future<void> _storeInstallTimings({
    required int clickS,
    required int beginS,
  }) async {
    if (beginS <= 0) return;
    if (clickS > 0 && beginS >= clickS) {
      await _prefs.setInt(_kClickToInstallS, beginS - clickS);
    }
    final openS = DateTime.now().millisecondsSinceEpoch ~/ 1000 - beginS;
    if (openS >= 0) await _prefs.setInt(_kInstallToOpenS, openS);
  }

  /// Links shared by older builds still carry `ref=<code>`; that alone marks the install a share.
  static bool _carriesRef(Map<String, String> params) =>
      params['ref']?.trim().isNotEmpty ?? false;

  @visibleForTesting
  static String? parseWallpaperTarget(String? raw) =>
      switch (parseReferrerPayload(raw)?.target) {
        WallpaperLinkTarget(:final id) => id,
        _ => null,
      };

  @visibleForTesting
  static String? parseRingtoneTarget(String? raw) =>
      switch (parseReferrerPayload(raw)?.target) {
        RingtoneLinkTarget(:final id) => id,
        _ => null,
      };

  @visibleForTesting
  static String? parseLang(String? raw) => parseReferrerPayload(raw)?.lang;

  /// Query the Install Referrer API once per install and persist any attribution, target and language.
  /// Safe on every launch — it self-guards.
  /// The one-shot is spent ONLY when Play actually ANSWERS; a failed bind is routine and transient.
  /// Retrying is free — the referrer stays available for 90 days and this runs off the startup path.
  Future<void> captureOnce() async {
    if (_prefs.containsKey(_kLegacyPendingCode)) {
      await _prefs.remove(_kLegacyPendingCode);
    }
    if (_prefs.getBool(_kChecked) ?? false) return;

    const debugReferrer = String.fromEnvironment('DEBUG_INSTALL_REFERRER');
    final useDebugReferrer = kDebugMode && debugReferrer.isNotEmpty;

    String? raw;
    // Did Play answer at all? A null `raw` from a successful call is a real answer and spends the shot.
    // A throw does not.
    var answered = false;
    if (useDebugReferrer) {
      raw = debugReferrer;
      answered = true;
    } else {
      try {
        final details = await PlayInstallReferrer.installReferrer;
        raw = details.installReferrer;
        answered = true;
        await _storeInstallTimings(
          clickS: details.referrerClickTimestampSeconds,
          beginS: details.installBeginTimestampSeconds,
        );
      } catch (e) {
        // No Play Services, or not an install-from-Play — expected in dev; ignore.
        debugPrint('[InstallReferrer] unavailable (non-fatal): $e');
      }
    }

    if (answered) {
      final play = raw == null
          ? const <String, String>{}
          : parseAttribution(raw);
      final attribution = _unattributed(play)
          ? withMetaReferrer(play, await _metaReferrer())
          : play;
      for (final MapEntry(:key, :value) in attribution.entries) {
        await _prefs.setString(key, value);
      }
    }
    if (raw != null) {
      final request = parseReferrerPayload(
        raw,
        source: useDebugReferrer
            ? DeepLinkSource.debug
            : DeepLinkSource.installReferrer,
      );
      if (request != null) {
        await queueRequest(request);
        debugPrint('[InstallReferrer] captured deep link: $request');
      }
    }
    if (answered) await _prefs.setBool(_kChecked, true);
  }

  Future<void> queueRequest(DeepLinkRequest request) async {
    final target = request.target;
    if (target != null) {
      await queueTarget(target);
    }
    final lang = request.lang;
    if (lang != null) {
      await queueLocale(lang);
    }
  }

  /// Durably queue a validated target and hand it to the live app.
  /// Last write wins across kinds — a ringtone replaces a pending wallpaper, never both keys.
  /// A tab-only target is NOT persisted: losing that race just lands the user on the default tab.
  /// Only install-time deliveries reach here, so the kind is also kept for [attributionProps] — and,
  /// unlike the pending target, never cleared once the tab has shown it.
  Future<void> queueTarget(DeepLinkTarget target) async {
    switch (target) {
      case WallpaperLinkTarget(:final id, :final source):
        final normalized = normalizeUuid(id);
        if (normalized == null) return;
        await _prefs.setString(_kPendingWallpaper, normalized);
        await _prefs.remove(_kPendingRingtone);
        await _prefs.remove(_kPendingStatus);
        await _prefs.setString(_kPendingSource, source.key);
        await _prefs.setString(_kInstallLink, target.kind);
        ArulDeepLink.requestTarget(
          WallpaperLinkTarget(normalized, source: source),
        );
      case RingtoneLinkTarget(:final id, :final source):
        final normalized = normalizeUuid(id);
        if (normalized == null) return;
        await _prefs.setString(_kPendingRingtone, normalized);
        await _prefs.remove(_kPendingWallpaper);
        await _prefs.remove(_kPendingStatus);
        await _prefs.setString(_kPendingSource, source.key);
        await _prefs.setString(_kInstallLink, target.kind);
        ArulDeepLink.requestTarget(
          RingtoneLinkTarget(normalized, source: source),
        );
      case StatusLinkTarget(:final id, :final source):
        final normalized = normalizeUuid(id);
        if (normalized == null) return;
        await _prefs.setString(_kPendingStatus, normalized);
        await _prefs.remove(_kPendingWallpaper);
        await _prefs.remove(_kPendingRingtone);
        await _prefs.setString(_kPendingSource, source.key);
        await _prefs.setString(_kInstallLink, target.kind);
        ArulDeepLink.requestTarget(
          StatusLinkTarget(normalized, source: source),
        );
      // Not persisted, handed straight to the live app. A tab-only target loses nothing by losing
      // the startup race; the other two are push-only (no URL parses into a category or the premium
      // screen), so nothing deferred can ever reach this branch carrying one.
      case TabLinkTarget():
      case CategoryLinkTarget():
      case PremiumLinkTarget():
        ArulDeepLink.requestTarget(target);
    }
  }

  Future<void> queueLocale(String code) async {
    final normalized = normalizeLang(code);
    if (normalized == null) return;
    await _prefs.setString(_kPendingLang, normalized);
    ArulDeepLink.requestLocale(normalized);
  }

  /// The target an ad or share click asked for before this install existed, or null.
  /// Consumed by the tab that shows it, which clears it via [clearPendingTarget].
  /// So a user who navigates away is never dragged back to it on the next launch.
  DeepLinkTarget? get pendingTarget {
    final source = DeepLinkSource.fromKey(_prefs.getString(_kPendingSource));
    final wallpaper = pendingWallpaperId;
    if (wallpaper != null) {
      return WallpaperLinkTarget(wallpaper, source: source);
    }
    final ringtone = pendingRingtoneId;
    if (ringtone != null) {
      return RingtoneLinkTarget(ringtone, source: source);
    }
    final status = pendingStatusId;
    if (status != null) {
      return StatusLinkTarget(status, source: source);
    }
    return null;
  }

  String? get pendingWallpaperId =>
      _nonEmpty(_prefs.getString(_kPendingWallpaper));

  String? get pendingRingtoneId =>
      _nonEmpty(_prefs.getString(_kPendingRingtone));

  String? get pendingStatusId => _nonEmpty(_prefs.getString(_kPendingStatus));

  String? get pendingLang => _nonEmpty(_prefs.getString(_kPendingLang));

  static String? _nonEmpty(String? v) => (v != null && v.isNotEmpty) ? v : null;

  /// Drop the pending target once the tab has jumped to it.
  /// The keys are never both set, so clearing all is the same as clearing "the" target.
  Future<void> clearPendingTarget() async {
    await _prefs.remove(_kPendingWallpaper);
    await _prefs.remove(_kPendingRingtone);
    await _prefs.remove(_kPendingStatus);
    await _prefs.remove(_kPendingSource);
  }

  Future<void> clearPendingLang() => _prefs.remove(_kPendingLang);
}
