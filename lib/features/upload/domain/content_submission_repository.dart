import '../../../data/models/content_submission_model.dart';

/// Read/create access to the user's content submissions.
abstract interface class ContentSubmissionRepository {
  /// Returns all submissions owned by [userId].
  Future<List<ContentSubmissionModel>> getSubmissions(String userId);

  /// Creates a new pending submission row.
  Future<ContentSubmissionModel> createSubmission({
    required String userId,
    required String kind,
    required String fileKey,
    String? title,
    String? category,
  });
}
