import 'package:flutter/foundation.dart';

import '../../../app/widgets/reel/reel_item.dart';

/// One status clip, from the Worker-built `catalog/statuses/all_{page}.json` (snake_case fields).
/// Every row is a clip with music -> unlike a wallpaper there is no still case.
@immutable
class StatusVideo implements ReelItem {
  const StatusVideo({
    required this.id,
    required this.title,
    required this.category,
    required this.key,
    this.durationMs,
    this.feedRank,
    this.publishedAt,
  });

  factory StatusVideo.fromJson(Map<String, dynamic> json) => StatusVideo(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    // An unknown or missing category must never crash the reel -> it falls into All.
    category: (json['category'] as String?) ?? 'other',
    key: json['full_key'] as String,
    durationMs: (json['duration_ms'] as num?)?.toInt(),
    feedRank: (json['feed_rank'] as num?)?.toInt(),
    publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
  );

  @override
  final String id;
  final String title;
  final String category;

  /// R2 object key, `statuses/<category>/<stem>.mp4` — public by design; browse is free.
  final String key;
  final int? durationMs;

  /// Position from build-catalog's ORDER BY; null only on a row the Worker could not number.
  final int? feedRank;
  final DateTime? publishedAt;

  String get categoryLabel => category.isEmpty
      ? category
      : category[0].toUpperCase() + category.substring(1);

  String url(String cdnBase) => '$cdnBase/$key';

  @override
  String videoUrl(String cdnBase) => url(cdnBase);

  /// `thumbs/statuses/<category>/<stem>.jpg`, derived from the KEY's own folder exactly as the
  /// Worker's sweep does -> a row moved to another category still finds the poster it was born with.
  String thumbUrl(String cdnBase) {
    final slash = key.lastIndexOf('/');
    final dir = slash == -1 ? '' : key.substring(0, slash + 1);
    final name = slash == -1 ? key : key.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot == -1 ? name : name.substring(0, dot);
    return '$cdnBase/thumbs/$dir$stem.jpg';
  }

  @override
  String posterUrl(String cdnBase) => thumbUrl(cdnBase);
}
