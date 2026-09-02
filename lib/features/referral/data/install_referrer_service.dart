import 'package:flutter/foundation.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/deeplink/deep_link_parser.dart';
import '../../../core/deeplink/deep_link_target.dart';

export '../../../core/deeplink/deep_link_parser.dart' show kDeepLinkHost;

/// Play Store package id — the share link points here with a `referrer` [captureOnce] reads back.
const String kPlayPackageId = 'com.hsrutility.arul';

/// Captures the Play Install Referrer ONCE per install and hands its code to the first sign-in.
/// Also the ONE durable home for every deferred deep-link target, whichever path delivered it.
///
///   1. the referrer shares [buildShareLink], or [buildWallpaperLink]/[buildRingtoneLink];
///   2. the friend installs, and Android's Install Referrer API replays that payload;
///   3. [captureOnce] parses ALL of it at startup and persists it;
///   4. the next `/auth/login` sends the code as `referralCode` and the Worker links the accounts.
///
/// [clearPendingCode] runs after login.
/// The target is consumed by the tab that shows it, the language by `DeepLinkLocaleSync`.
/// Android-only, and a no-op without Play Services -> a missing referrer never affects launch.
class InstallReferrerService {
  InstallReferrerService(this._prefs);

  final SharedPreferences _prefs;

  static const _kPendingCode = 'pending_referral_code';
  static const _kPendingWallpaper = 'pending_deeplink_wallpaper';
  static const _kPendingRingtone = 'pending_deeplink_ringtone';
  static const _kPendingSource = 'pending_deeplink_source';
  static const _kPendingLang = 'pending_deeplink_lang';
  static const _kChecked = 'install_referrer_checked';

  /// The shareable Play Store link that embeds [code] for attribution.
  ///
  /// For surfaces with no wallpaper to point at — Refer & Earn, Settings, the post-* sheets.
  /// A wallpaper share uses [buildWallpaperLink], which carries the code the same way.
  static String buildShareLink(String code) {
    // `referrer` value = "ref=<CODE>"; URL-encoded so Play preserves it verbatim.
    final referrer = Uri.encodeQueryComponent('ref=$code');
    return 'https://play.google.com/store/apps/details'
        '?id=$kPlayPackageId&referrer=$referrer';
  }

  /// The ONE link a wallpaper share or ad creative carries — an App Link on [kDeepLinkHost].
  ///
  /// Optionally attributed to [code], and optionally asking for a UI language via [lang].
  /// It resolves TWO ways from a single URL, which is why it is https on our own host:
  ///   · INSTALLED — Android verified this host at install, intercepts before any browser;
  ///   · NOT installed — the Worker's `/w/:id` redirects to Play carrying the referrer payload.
  ///
  /// Android replays that to [captureOnce] -> the WALLPAPER opens after the install, not just the app.
  /// A custom scheme cannot do the first half — it is not a clickable URL in an ad or a messenger.
  /// [installLang] is the SHARE form of [lang]: the sharer's UI language, honoured on a fresh install.
  /// It rides as `ilang=`, which [parseDeepLinkUri] deliberately does not read.
  /// So a friend's Tamil share never re-languages an app the recipient already set to Hindi.
  /// A brand-new install still opens in the language the caption is written in (owner's call).
  /// Ads keep using [lang], which wins everywhere; the Worker folds `ilang` into the referrer's `lang=`.
  static String buildWallpaperLink(
    String wallpaperId, {
    String? code,
    String? lang,
    String? installLang,
  }) => _buildLink(
    'w',
    wallpaperId,
    code: code,
    lang: lang,
    installLang: installLang,
  );

  /// The ringtone form of [buildWallpaperLink] — `/r/<id>`. Nothing in the app shares a ringtone.
  /// It exists so ad creatives are built from ONE place and never by hand.
  static String buildRingtoneLink(
    String ringtoneId, {
    String? code,
    String? lang,
    String? installLang,
  }) => _buildLink(
    'r',
    ringtoneId,
    code: code,
    lang: lang,
    installLang: installLang,
  );

  static String _buildLink(
    String segment,
    String id, {
    String? code,
    String? lang,
    String? installLang,
  }) {
    final query = <String>[
      if (code != null && code.isNotEmpty) 'ref=$code',
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

  /// Extract our referral code from a raw install-referrer string.
  /// Handles both the "ref=CODE" query form we set and a bare code, and rejects junk.
  @visibleForTesting
  static String? parseReferralCode(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;

    // Preferred: our key inside a (possibly utm-augmented) query string.
    try {
      final params = Uri.splitQueryString(s);
      final v = params['ref'] ?? params['referral'] ?? params['code'];
      final cleaned = _clean(v);
      if (cleaned != null) return cleaned;
    } catch (_) {
      // fall through to bare-value handling
    }

    // Fallback: Play returned exactly the bare value we set.
    if (!s.contains('=') && !s.contains('&')) return _clean(s);
    return null;
  }

  static String? _clean(String? v) {
    if (v == null) return null;
    final c = v.trim().toUpperCase();
    return RegExp(r'^[A-Z0-9]{4,16}$').hasMatch(c) ? c : null;
  }

  /// The wallpaper tapped BEFORE they had the app — the `w=<uuid>` half of the Worker's payload.
  /// Validated as a UUID: see `normalizeUuid`.
  @visibleForTesting
  static String? parseWallpaperTarget(String? raw) =>
      switch (parseReferrerPayload(raw)?.target) {
        WallpaperLinkTarget(:final id) => id,
        _ => null,
      };

  /// The ringtone half (`r=<uuid>`) of the same payload.
  @visibleForTesting
  static String? parseRingtoneTarget(String? raw) =>
      switch (parseReferrerPayload(raw)?.target) {
        RingtoneLinkTarget(:final id) => id,
        _ => null,
      };

  /// The `lang=<code>` half, reduced to one of the six shipped codes.
  @visibleForTesting
  static String? parseLang(String? raw) => parseReferrerPayload(raw)?.lang;

  /// Query the Install Referrer API once per install and persist any code, target and language.
  /// Safe on every launch — it self-guards.
  ///
  /// The one-shot is spent ONLY when Play actually ANSWERS; a failed bind is routine and transient.
  /// Google's guidance is that the connection can drop mid-update and must be restarted.
  /// Marking the install checked on a throw burned the shot and lost the code for good.
  /// Retrying is free — the referrer stays available for 90 days and this runs off the startup path.
  /// A device with no Play Store throws every launch and retries forever, having nothing to lose.
  Future<void> captureOnce() async {
    if (_prefs.getBool(_kChecked) ?? false) return;

    // Test seam: `--dart-define=DEBUG_INSTALL_REFERRER=…` stands in for Play's replay.
    // A real referrer needs a Play install of THIS build -> this drives it on a sideload.
    // Const-gated on kDebugMode -> release builds compile it away.
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
        raw = (await PlayInstallReferrer.installReferrer).installReferrer;
        answered = true;
      } catch (e) {
        // No Play Services, or not an install-from-Play — expected in dev; ignore.
        debugPrint('[InstallReferrer] unavailable (non-fatal): $e');
      }
    }

    if (raw != null) {
      final code = parseReferralCode(raw);
      if (code != null) {
        await _prefs.setString(_kPendingCode, code);
        debugPrint('[InstallReferrer] captured referral code');
      }
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

  /// Persist and hand over everything one link asked for.
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
  ///
  /// Shared by the Play referrer, GA4F and the Meta SDK bridges.
  /// Persisting BEFORE the live request is load-bearing -> a process death is re-seeded at startup.
  /// Last write wins across kinds — a ringtone replaces a pending wallpaper, never both keys.
  /// A tab-only target is NOT persisted: losing that race just lands the user on the default tab.
  Future<void> queueTarget(DeepLinkTarget target) async {
    switch (target) {
      case WallpaperLinkTarget(:final id, :final source):
        final normalized = normalizeUuid(id);
        if (normalized == null) return;
        await _prefs.setString(_kPendingWallpaper, normalized);
        await _prefs.remove(_kPendingRingtone);
        await _prefs.setString(_kPendingSource, source.key);
        ArulDeepLink.requestTarget(
          WallpaperLinkTarget(normalized, source: source),
        );
      case RingtoneLinkTarget(:final id, :final source):
        final normalized = normalizeUuid(id);
        if (normalized == null) return;
        await _prefs.setString(_kPendingRingtone, normalized);
        await _prefs.remove(_kPendingWallpaper);
        await _prefs.setString(_kPendingSource, source.key);
        ArulDeepLink.requestTarget(
          RingtoneLinkTarget(normalized, source: source),
        );
      case TabLinkTarget():
        ArulDeepLink.requestTarget(target);
    }
  }

  /// Durably queue a validated language and hand it to the live app.
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
    return null;
  }

  String? get pendingWallpaperId =>
      _nonEmpty(_prefs.getString(_kPendingWallpaper));

  String? get pendingRingtoneId =>
      _nonEmpty(_prefs.getString(_kPendingRingtone));

  /// The language the link asked for, until `DeepLinkLocaleSync` applies it.
  String? get pendingLang => _nonEmpty(_prefs.getString(_kPendingLang));

  static String? _nonEmpty(String? v) => (v != null && v.isNotEmpty) ? v : null;

  /// Drop the pending target once the tab has jumped to it.
  /// The two keys are never both set, so clearing both is the same as clearing "the" target.
  Future<void> clearPendingTarget() async {
    await _prefs.remove(_kPendingWallpaper);
    await _prefs.remove(_kPendingRingtone);
    await _prefs.remove(_kPendingSource);
  }

  /// Drop the pending language once it has been applied.
  Future<void> clearPendingLang() => _prefs.remove(_kPendingLang);

  /// The pending referral code to attach to the next login, or null.
  String? get pendingCode => _nonEmpty(_prefs.getString(_kPendingCode));

  /// Drop the pending code once it has been consumed by a successful login.
  Future<void> clearPendingCode() => _prefs.remove(_kPendingCode);
}
