/// One page of a vertical reel — what the shared player pool and prefetcher need to know about it.
abstract interface class ReelItem {
  String get id;

  /// The clip this page plays, or null for a still, which never takes a player or a prefetch slot.
  String? videoUrl(String cdnBase);

  /// The still mounted under the texture until the clip paints.
  String posterUrl(String cdnBase);
}
