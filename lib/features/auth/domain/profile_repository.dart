/// Read/write access to the user's `profiles` row.
abstract interface class ProfileRepository {
  /// Creates a profiles row on first sign-in, ignoring duplicates.
  Future<void> upsertOnFirstLogin({
    required String userId,
    required String? displayName,
  });

  /// Returns the profiles row for [userId], or null if not found.
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
