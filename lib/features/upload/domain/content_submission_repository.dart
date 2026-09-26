import '../../../data/models/content_submission_model.dart';

abstract interface class ContentSubmissionRepository {
  Future<List<ContentSubmissionModel>> getSubmissions(String userId);

  Future<ContentSubmissionModel> createSubmission({
    required String userId,
    required String kind,
    required String fileKey,
    String? title,
    String? category,
  });
}
