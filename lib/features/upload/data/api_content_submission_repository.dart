import '../../../core/api/api_client.dart';
import '../../../data/models/content_submission_model.dart';
import '../domain/content_submission_repository.dart';

/// Reads and creates the user's content submissions via the Worker.
class ApiContentSubmissionRepository implements ContentSubmissionRepository {
  const ApiContentSubmissionRepository({required ApiClient apiClient})
    : _api = apiClient;

  final ApiClient _api;

  @override
  Future<List<ContentSubmissionModel>> getSubmissions(String userId) async {
    // GET /me/submissions (Worker, architecture.md §3.5) → { items: [...] }; 404 → [].
    try {
      final data = await _api.get('/me/submissions');
      final items = data['items'] as List? ?? [];
      return items
          .cast<Map<String, dynamic>>()
          .map(ContentSubmissionModel.fromJson)
          .toList();
    } on ApiException catch (e) {
      if (e.status == 404) return [];
      rethrow;
    }
  }

  @override
  /// Confirms an uploaded file with the Worker and returns the new (pending)
  /// submission, inflated from the request fields for immediate display.
  Future<ContentSubmissionModel> createSubmission({
    required String userId,
    required String kind,
    required String fileKey,
    String? title,
    String? category,
  }) async {
    final data = await _api.post(
      '/media/confirm-upload',
      body: {
        'kind': kind,
        'fileKey': fileKey,
        'title': title,
        'category': category,
      },
    );
    // Worker returns { "id": "...", "status": "pending" } — inflate into a
    // full model by merging request fields so the UI can render it immediately.
    return ContentSubmissionModel.fromJson({
      'id': data['id'],
      'user_id': userId,
      'kind': kind,
      'file_key': fileKey,
      'title': title,
      'category': category,
      'status': data['status'] ?? 'pending',
    });
  }
}
