import 'package:flutter_test/flutter_test.dart';

import 'package:arul/core/deeplink/deep_link_target.dart';
import 'package:arul/features/push/domain/push_payload.dart';

/// The tap path's one testable piece: what a campaign's `data` map opens.
///
/// The contract this pins is **every unreadable payload lands on home**. A campaign composed against
/// a newer app, a wallpaper deleted since the send, a category retired last week — none of them may
/// crash or show an error screen. The person tapped a notification we chose to send them.
void main() {
  const wallpaperId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  group('pushTargetFor', () {
    test('a wallpaper opens the wallpaper, stamped as a push', () {
      final target = pushTargetFor({'dest': 'wallpaper', 'id': wallpaperId});
      expect(target, isA<WallpaperLinkTarget>());
      expect((target! as WallpaperLinkTarget).id, wallpaperId);
      // Not app_link: every campaign tap parks in the same slot a link does, and the tab that shows
      // it fires `deep_link_opened`. Without its own source, push traffic would inflate ad channels.
      expect(target.source, DeepLinkSource.push);
    });

    test('a ringtone opens the ringtone — and the two never cross', () {
      final target = pushTargetFor({'dest': 'ringtone', 'id': wallpaperId});
      expect(target, isA<RingtoneLinkTarget>());
      expect(target!.tab, ArulTab.ringtones);
    });

    test('a category opens the browse feed filtered', () {
      final target = pushTargetFor({'dest': 'category', 'id': 'ganapathi'});
      expect(target, isA<CategoryLinkTarget>());
      expect((target! as CategoryLinkTarget).slug, 'ganapathi');
    });

    test('premium opens the premium screen and needs no id', () {
      expect(pushTargetFor({'dest': 'premium'}), isA<PremiumLinkTarget>());
    });

    test(
      'home is null — the app is already opening, that IS the destination',
      () {
        expect(pushTargetFor({'dest': 'home'}), isNull);
        expect(pushTargetFor({}), isNull);
      },
    );

    test('EVERY unreadable payload falls back to home instead of throwing', () {
      final payloads = <Map<String, Object?>>[
        {'dest': 'wallpaper'}, // no id at all
        {'dest': 'wallpaper', 'id': ''},
        {'dest': 'wallpaper', 'id': 'not-a-uuid'},
        {'dest': 'ringtone', 'id': '123'},
        {'dest': 'category', 'id': ''},
        {'dest': 'screen'}, // a destination this build has never heard of
        {'dest': ''},
        {'dest': 42}, // the Worker only ever writes strings; survive it anyway
        {'id': wallpaperId}, // an id with no destination
      ];
      for (final payload in payloads) {
        expect(
          () => pushTargetFor(payload),
          returnsNormally,
          reason: '$payload must never throw',
        );
        expect(
          pushTargetFor(payload),
          isNull,
          reason: '$payload must open home',
        );
      }
    });

    test('a destination and a uuid are case-insensitive and trimmed', () {
      final target = pushTargetFor({
        'dest': ' Wallpaper ',
        'id': wallpaperId.toUpperCase(),
      });
      expect((target! as WallpaperLinkTarget).id, wallpaperId);
    });
  });

  group('pushCampaignId', () {
    test('reads a well-formed uuid and nothing else', () {
      expect(pushCampaignId({'campaign_id': wallpaperId}), wallpaperId);
      // Junk is dropped rather than reported: the Worker would only answer 400, and a tap must not
      // spend a request proving that.
      expect(pushCampaignId({'campaign_id': 'nope'}), isNull);
      expect(pushCampaignId({'campaign_id': ''}), isNull);
      expect(pushCampaignId({}), isNull);
      expect(pushCampaignId({'campaign_id': 7}), isNull);
    });
  });
}
