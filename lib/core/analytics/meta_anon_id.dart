import 'package:facebook_app_events/facebook_app_events.dart';

import '../config/app_config.dart';

/// Meta SDK anonymous app device GUID (`AppEventsLogger.getAnonymousAppDeviceGUID`
/// on Android — "XZ" + UUID) — the device join key the Worker needs to report
/// the FIRST trial→paid conversion via the Conversions API for debits that
/// settle with the app closed. Uploaded with /auth/login and /payments/initiate;
/// stored on the `users` row (users.meta_anon_id, read by workers lib/meta.ts).
///
/// This is the same id the native SDK stamps on its auto-logged install and the
/// client-side StartTrial, so the server event joins the device Meta already
/// attributed the install to — hashed email/external_id alone match the person,
/// not the ad-clicking device.
///
/// Null when Meta is off (`flutter test`, key-less dev builds) or the platform
/// call fails — callers omit the field and the Worker keeps whatever id it
/// already has. The id changes on reinstall/clear-data, which always forces a
/// fresh sign-in, so the login upload keeps it current.
Future<String?> fetchMetaAnonId() async {
  if (!AppConfig.metaEnabled) return null;
  try {
    return await FacebookAppEvents().getAnonymousId();
  } catch (_) {
    // Fire-and-forget metadata — never let analytics break sign-in or payment.
    return null;
  }
}
