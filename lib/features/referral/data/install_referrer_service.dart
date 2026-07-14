import 'package:flutter/foundation.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Play Store package id — the Refer & Earn share link points here with a
/// `referrer` payload that [captureOnce] reads back after the friend installs.
const String kPlayPackageId = 'com.hsrapps.arul';

/// Captures the Play Install Referrer once per install and hands the extracted
/// referral code to the first sign-in.
///
/// Flow:
///   1. Referrer shares [buildShareLink] (a Play Store URL carrying `ref=<CODE>`).
///   2. Friend installs; Android's Install Referrer API replays that payload.
///   3. [captureOnce] (run at startup) parses the code and persists it.
///   4. The next `/auth/login` sends it as `referralCode`; the Worker links the
///      accounts on new-user creation. [clearPendingCode] runs after login.
///
/// Android-only; degrades to a no-op if Play Services are unavailable (sideload,
/// emulator without Play, iOS) — a missing referrer must never affect launch.
class InstallReferrerService {
  InstallReferrerService(this._prefs);

  final SharedPreferences _prefs;

  static const _kPendingCode = 'pending_referral_code';
  static const _kChecked = 'install_referrer_checked';

  /// Build the shareable Play Store link that embeds [code] for attribution.
  static String buildShareLink(String code) {
    // `referrer` value = "ref=<CODE>"; URL-encoded so Play preserves it verbatim.
    final referrer = Uri.encodeQueryComponent('ref=$code');
    return 'https://play.google.com/store/apps/details'
        '?id=$kPlayPackageId&referrer=$referrer';
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

  /// Query the Install Referrer API at most once per install and persist any
  /// referral code found. Safe to call on every launch (it self-guards).
  Future<void> captureOnce() async {
    if (_prefs.getBool(_kChecked) ?? false) return;
    try {
      final details = await PlayInstallReferrer.installReferrer;
      final code = parseReferralCode(details.installReferrer);
      if (code != null) {
        await _prefs.setString(_kPendingCode, code);
        debugPrint('[InstallReferrer] captured referral code');
      }
    } catch (e) {
      // No Play Services / not an install-from-Play — expected in dev; ignore.
      debugPrint('[InstallReferrer] unavailable (non-fatal): $e');
    }
    await _prefs.setBool(_kChecked, true);
  }

  /// The pending referral code to attach to the next login, or null.
  String? get pendingCode {
    final code = _prefs.getString(_kPendingCode);
    return (code != null && code.isNotEmpty) ? code : null;
  }

  /// Drop the pending code once it has been consumed by a successful login.
  Future<void> clearPendingCode() => _prefs.remove(_kPendingCode);
}
