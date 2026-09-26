abstract interface class ProfileRepository {
  Future<void> upsertOnFirstLogin({
    required String userId,
    required String? displayName,
  });

  Future<Map<String, dynamic>?> getProfile(String userId);

  /// Updates editable profile fields for [userId].
  /// A null field -> not written -> pass only what changed.
  Future<void> updateProfile(
    String userId, {
    String? displayName,
    bool? statusShowPhoto,
    bool? statusShowName,
  });
}
