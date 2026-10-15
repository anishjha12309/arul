import 'package:arul/data/models/wallpaper.dart';
import 'package:arul/features/status/domain/status_video.dart';
import 'package:arul/features/status/providers/status_providers.dart';
import 'package:flutter_test/flutter_test.dart';

// Builds that predate the photo slot read the same catalog: a row carrying `photo_slot`, a
// 768×1152 clip or a language they have never seen must still parse and play.
void main() {
  Map<String, dynamic> row(String id, String category, {Object? slot}) => {
    'id': id,
    'title': 'clip $id',
    'category': category,
    'full_key': 'statuses/$category/$id.mp4',
    'duration_ms': 29800,
    'width': 768,
    'height': 1152,
    'is_published': true,
    'feed_rank': 1,
    'published_at': '2026-10-15T20:00:00Z',
    'photo_slot': ?slot,
  };

  test('a row with photo_slot, a 768x1152 clip and a new language parses', () {
    final s = StatusVideo.fromJson(
      row(
        'a',
        'kannada',
        slot: {'left': 0.3583, 'top': 0.6865, 'size': 0.2917, 'shape': 'pin'},
      ),
    );
    expect(s.aspect, closeTo(1.5, 1e-9));
    expect(s.categoryLabel, 'Kannada');
    expect(s.key, 'statuses/kannada/a.mp4');
  });

  test('a malformed photo_slot never breaks the row', () {
    for (final bad in <Object>['x', 42, <String, Object>{}, <Object>[]]) {
      expect(() => StatusVideo.fromJson(row('b', 'malayalam', slot: bad)),
          returnsNormally);
    }
  });

  test('new languages filter like any category', () {
    final all = [
      StatusVideo.fromJson(row('1', 'tamil')),
      StatusVideo.fromJson(row('2', 'malayalam')),
      StatusVideo.fromJson(row('3', 'kannada')),
    ];
    expect(statusFeedOrder('malayalam', all).map((s) => s.id), ['2']);
    expect(statusFeedOrder(WallpaperCategory.allSlug, all), hasLength(3));
  });
}
