import 'package:flutter/foundation.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/deeplink/deep_link_parser.dart';
import '../../../core/deeplink/deep_link_target.dart';

export '../../../core/deeplink/deep_link_parser.dart' show kDeepLinkHost;

/// Play Store package id — the Refer & Earn share link points here with a
/// `referrer` payload that [captureOnce] reads back after the friend installs.
const String kPlayPackageId = 'com.hsrutility.arul';

/// Captures the Play Install Referrer once per install, hands the extracted
/// referral code to the first sign-in, and is the ONE durable home for every
/// deferred deep-link target — whichever path delivered it.
///
/// Flow:
///   1. Referrer shares [buildShareLink] (a Play Store URL carrying `ref=<CODE>`)
///      or [buildWallpaperLink] / [buildRingtoneLink] (App Links, which
///      additionally carry the target, and optionally `lang`).
///   2. Friend installs; Android's Install Referrer API replays that payload.
///   3. [captureOnce] (run at startup) parses ALL of it and persists it.
///   4. The next `/auth/login` sends the code as `referralCode`; the Worker links
///      the accounts on new-user creation. [clearPendingCode] runs after login.
///      The target is consumed separately by the tab that shows it, and the
///      language by `DeepLinkLocaleSync` — see [pendingTarget], [pendingLang].
///
/// Android-only; degrades to a no-op if Play Services are unavailable (sideload,
/// emulator without Play, iOS) — a missing referrer must never affect launch.
class InstallReferrerService {
  InstallReferrerService(this._prefs);

  final SharedPreferences _prefs;

  static const _kPendingCode = 'pending_referral_code';
  static const _kPendingWallpaper = 'pending_deeplink_wallpaper';
  static const _kPendingRingtone = 'pending_deeplink_ringtone';
  static const _kPendingSource = 'pending_deeplink_source';
  static const _kPendingLang = 'pending_deeplink_lang';
  static const _kChecked = 'install_referrer_checked';

  /// Build the shareable Play Store link that embeds [code] for attribution.
  ///
  /// Used where there is no wallpaper to point at — Refer & Earn, Settings, the
  /// post-purchase and post-upload sheets. A wallpaper share uses
  /// [buildWallpaperLink] instead, which carries the code the same way.
  static String buildShareLink(String code) {
    // `referrer` value = "ref=<CODE>"; URL-encoded so Play preserves it verbatim.
    final referrer = Uri.encodeQueryComponent('ref=$code');
    return 'https://play.google.com/store/apps/details'
        '?id=$kPlayPackageId&referrer=$referrer';
  }

  /// The ONE link a wallpaper share (or an ad creative) carries: an App Link on
  /// [kDeepLinkHost] pointing at [wallpaperId], optionally attributed to [code]
  /// and optionally asking for a UI language ([lang], one of the six codes —
  /// what an ad in that language sets).
  ///
  /// It resolves two ways from a single URL, which is the entire reason it is an
  /// https link on our own host rather than a Play URL or an `arul://` scheme:
  ///   · App INSTALLED — Android verified this host at install time, intercepts
  ///     before any browser, and hands the id straight to the app.
  ///   · NOT installed — nothing intercepts, the Worker's `/w/:id` answers and
  ///     redirects to Play carrying `referrer=ref=<code>&w=<id>&lang=<lang>`,
  ///     which Android replays to [captureOnce] on first launch. That is what
  ///     makes the wallpaper open AFTER the install, not just the app.
  ///
  /// A custom scheme cannot do the first half from an ad or a messenger: it is
  /// not a clickable URL, so it renders as plain text and resolves to nothing.
  /// [installLang] is the SHARE form of [lang]: the sharer's current UI
  /// language, honoured only when the link ends in a fresh install. It rides as
  /// `ilang=`, which [parseDeepLinkUri] deliberately does not read — so tapping
  /// a friend's Tamil share never re-languages an app the recipient already set
  /// to Hindi, while a brand-new install still opens in the language the caption
  /// is written in (owner's call, 2026-08-27). Ads keep using [lang], which wins
  /// everywhere. The Worker folds `ilang` into the referrer's `lang=`.
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

  /// The ringtone form of [buildWallpaperLink]: `/r/<id>`. Nothing in the app
  /// shares a ringtone (there is no ringtone share path); this exists so ad
  /// creatives are built from one place and never by hand.
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

  /// Extract our referral code from a raw install-referrer string. Handles both
  /// the "ref=CODE" query form we set and a bare code, and rejects junk.
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

  /// The wallpaper the person tapped BEFORE they had the app, from a raw
  /// install-referrer string — the `w=<uuid>` half of the Worker's payload.
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

  /// Query the Install Referrer API once per install and persist any referral
  /// code, deep-link target and language found. Safe to call on every launch
  /// (it self-guards).
  ///
  /// The one-shot is spent only when Play ACTUALLY ANSWERS. A failed bind is
  /// routine and transient — Google's own guidance is that the client "may lose
  /// the connection if the Play Store service is updating in the background"
  /// and "must call the startConnection() method to restart the connection".
  /// Marking the install checked on a throw burned the shot on that, losing the
  /// referral code and deep-link target for good with nothing logged. Retrying
  /// is free: the referrer stays available for 90 days and this runs unawaited
  /// off the startup path. A device with no Play Store throws every launch and
  /// so retries forever — a failed AIDL bind, and it has no referrer to lose.
  Future<void> captureOnce() async {
    if (_prefs.getBool(_kChecked) ?? false) return;

    // Test seam: `--dart-define=DEBUG_INSTALL_REFERRER='w=<uuid>&lang=hi'`
    // stands in for Play's replay so the not-installed path can be driven on a
    // sideloaded debug build (a real referrer needs a Play install of THIS
    // build). Const-gated on kDebugMode, so release builds compile it away.
    const debugReferrer = String.fromEnvironment('DEBUG_INSTALL_REFERRER');
    final useDebugReferrer = kDebugMode && debugReferrer.isNotEmpty;

    String? raw;
    // Did Play answer at all? A null `raw` from a successful call is a real
    // answer (an organic install has no referrer) and still spends the shot;
    // a throw does not.
    var answered = false;
    if (useDebugReferrer) {
      raw = debugReferrer;
      answered = true;
    } else {
      try {
        raw = (await PlayInstallReferrer.installReferrer).installReferrer;
        answered = true;
      } catch (e) {
        // No Play Services / not an install-from-Play — expected in dev; ignore.
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
  /// Shared by the Play referrer, GA4F and the Meta SDK bridges. Persisting
  /// before the live request is load-bearing: if the process dies or the async
  /// result loses the first-catalog race, startup re-seeds it (main.dart).
  /// Last write wins across kinds — a ringtone link replaces a pending
  /// wallpaper, so the two keys are never both set.
  ///
  /// A tab-only target is not persisted: if it loses the startup race the user
  /// simply lands on the default tab, which is not worth a pref.
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

  /// The target an ad/share click asked for before this install existed, or
  /// null. Consumed by the tab that shows it (the feed for a wallpaper, the
  /// Ringtones tab for a ringtone), which clears it via [clearPendingTarget],
  /// so a user who navigates away is never dragged back to it on the next
  /// launch.
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

  /// Drop the pending target once the tab has jumped to it (either kind — the
  /// two keys are never both set, so clearing both is the same as clearing
  /// "the" target).
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
