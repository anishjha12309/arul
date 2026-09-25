import 'package:in_app_review/in_app_review.dart';

/// The Play review sheet, as a seam — `flutter test` has no Play Store to talk to.
abstract interface class ReviewLauncher {
  Future<bool> isAvailable();

  /// Completes when Play's flow ends. It never says whether a sheet showed or a rating was left.
  Future<void> requestReview();
}

/// `in_app_review`: Android answers `isAvailable` from a `requestReviewFlow` round trip, and
/// `requestReview` throws a `PlatformException` when that flow fails or no Activity is attached.
class PlayReviewLauncher implements ReviewLauncher {
  const PlayReviewLauncher();

  @override
  Future<bool> isAvailable() => InAppReview.instance.isAvailable();

  @override
  Future<void> requestReview() => InAppReview.instance.requestReview();
}
