import 'package:firebase_analytics/firebase_analytics.dart';

import '../config/app_config.dart';

/// Firebase Analytics `app_instance_id` — the join key the Worker needs to
/// report `purchase` via the GA4 Measurement Protocol for debits that settle
/// with the app closed (trial→paid, monthly renewals). Uploaded with
/// /auth/login and /payments/initiate; stored on the `users` row.
///
/// Null when Firebase is off (`flutter test`, key-less dev builds) or the
/// platform call fails — callers omit the field and the Worker keeps whatever
/// id it already has. The id changes on reinstall/clear-data, which always
/// forces a fresh sign-in, so the login upload keeps it current.
Future<String?> fetchAppInstanceId() async {
  if (!AppConfig.firebaseEnabled) return null;
  try {
    return await FirebaseAnalytics.instance.appInstanceId;
  } catch (_) {
    // Fire-and-forget metadata — never let analytics break sign-in or payment.
    return null;
  }
}
