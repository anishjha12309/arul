import 'package:flutter/foundation.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/deeplink/deep_link_target.dart';

/// Play Store package id — the Refer & Earn share link points here with a
/// `referrer` payload that [captureOnce] reads back after the friend installs.
const String kPlayPackageId = 'com.hsrutility.arul';

/// Host of the verified Android App Link.
///
/// MUST stay identical to three other places or deep links silently fall back to
/// opening a browser, with nothing logged anywhere:
///   · the `<data android:host>` of the App Links intent-filter in AndroidManifest.xml
///   · the `[[routes]]` custom domain in workers/wrangler.toml
///   · the host serving /.well-known/assetlinks.json (the same Worker)
const String kDeepLinkHost = 'arul.hsrutility.com';

/// Captures the Play Install Referrer once per install and hands the extracted
/// referral code to the first sign-in.
///
/// Flow:
///   1. Referrer shares [buildShareLink] (a Play Store URL carrying `ref=<CODE>`)
///      or [buildWallpaperLink] (an App Link, which additionally carries `w=<id>`).
///   2. Friend installs; Android's Install Referrer API replays that payload.
///   3. [captureOnce] (run at startup) parses BOTH and persists them.
///   4. The next `/auth/login` sends the code as `referralCode`; the Worker links
///      the accounts on new-user creation. [clearPendingCode] runs after login.
///      The wallpaper id is consumed separately by the feed — see
///      [pendingWallpaperId].
///
/// Android-only; degrades to a no-op if Play Services are unavailable (sideload,
/// emulator without Play, iOS) — a missing referrer must never affect launch.
class InstallReferrerService {
  InstallReferrerService(this._prefs);

  final SharedPreferences _prefs;

  static const _kPendingCode = 'pending_referral_code';
  static const _kPendingWallpaper = 'pending_deeplink_wallpaper';
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
  /// [kDeepLinkHost] pointing at [wallpaperId], optionally attributed to [code].
  ///
  /// It resolves two ways from a single URL, which is the entire reason it is an
  /// https link on our own host rather than a Play URL or an `arul://` scheme:
  ///   · App INSTALLED — Android verified this host at install time, intercepts
  ///     before any browser, and hands the id straight to the app.
  ///   · NOT installed — nothing intercepts, the Worker's `/w/:id` answers and
  ///     redirects to Play carrying `referrer=ref=<code>&w=<id>`, which Android
  ///     replays to [captureOnce] on first launch. That is what makes the
  ///     wallpaper open AFTER the install, not just the app.
  ///
  /// A custom scheme cannot do the first half from an ad or a messenger: it is
  /// not a clickable URL, so it renders as plain text and resolves to nothing.
  static String buildWallpaperLink(String wallpaperId, {String? code}) {
    final query = (code != null && code.isNotEmpty) ? '?ref=$code' : '';
    return 'https://$kDeepLinkHost/w/$wallpaperId$query';
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

  /// Extract the deferred deep-link target — the wallpaper the person tapped
  /// BEFORE they had the app — from a raw install-referrer string.
  ///
  /// Separate from [parseReferralCode] because the two are independent: an ad
  /// click carries `w=` with no `ref=`, and a plain Refer & Earn share carries
  /// `ref=` with no `w=`. Either half missing must not discard the other.
  ///
  /// Validated as a UUID rather than passed through: this string arrives from
  /// outside the app and is about to select a row, and a bare-value referrer
  /// (utm campaigns, Play's own test payloads) must resolve to null, not to a
  /// lookup for something that will never match.
  @visibleForTesting
  static String? parseWallpaperTarget(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    try {
      final v = Uri.splitQueryString(s)['w']?.trim().toLowerCase();
      if (v == null) return null;
      return RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(v)
          ? v
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Query the Install Referrer API at most once per install and persist any
  /// referral code and deep-link target found. Safe to call on every launch (it
  /// self-guards).
  Future<void> captureOnce() async {
    if (_prefs.getBool(_kChecked) ?? false) return;
    try {
      final details = await PlayInstallReferrer.installReferrer;
      final raw = details.installReferrer;
      final code = parseReferralCode(raw);
      if (code != null) {
        await _prefs.setString(_kPendingCode, code);
        debugPrint('[InstallReferrer] captured referral code');
      }
      final wallpaperId = parseWallpaperTarget(raw);
      if (wallpaperId != null) {
        // Persist AND hand over live. This call races the feed's first catalog
        // drain: the live handover wins when Play answers quickly, the persisted
        // copy covers the next launch when it doesn't. Whoever consumes it
        // clears the pref, so the user is taken there exactly once.
        await _prefs.setString(_kPendingWallpaper, wallpaperId);
        ArulDeepLink.request(wallpaperId);
        debugPrint('[InstallReferrer] captured deep-link wallpaper');
      }
    } catch (e) {
      // No Play Services / not an install-from-Play — expected in dev; ignore.
      debugPrint('[InstallReferrer] unavailable (non-fatal): $e');
    }
    await _prefs.setBool(_kChecked, true);
  }

  /// The wallpaper an ad/share click asked for before this install existed, or
  /// null. Consumed by the feed on first paint via [clearPendingWallpaper], so a
  /// user who navigates away is never dragged back to it on the next launch.
  String? get pendingWallpaperId {
    final id = _prefs.getString(_kPendingWallpaper);
    return (id != null && id.isNotEmpty) ? id : null;
  }

  /// Drop the pending deep-link target once the feed has jumped to it.
  Future<void> clearPendingWallpaper() => _prefs.remove(_kPendingWallpaper);

  /// The pending referral code to attach to the next login, or null.
  String? get pendingCode {
    final code = _prefs.getString(_kPendingCode);
    return (code != null && code.isNotEmpty) ? code : null;
  }

  /// Drop the pending code once it has been consumed by a successful login.
  Future<void> clearPendingCode() => _prefs.remove(_kPendingCode);
}
