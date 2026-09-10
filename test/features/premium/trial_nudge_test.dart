// The unfinished-trial nudge: who gets asked again, and who must never be.
//
// The row and the reminder both say "free trial". Saying that to a user who spent theirs — and was
// abandoning a ₹199 charge — is the failure this file exists to stop, alongside the plainer one of
// still nagging someone whose payment actually landed.
import 'package:arul/core/providers/shared_preferences_provider.dart';
import 'package:arul/features/notifications/data/notification_service.dart';
import 'package:arul/features/notifications/providers/notification_providers.dart';
import 'package:arul/features/premium/domain/trial_nudge.dart';
import 'package:arul/features/premium/providers/trial_nudge_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what was armed without touching a platform channel.
class _FakeNotifications implements NotificationService {
  bool enabled = true;
  DateTime? armedFor;
  int cancels = 0;

  @override
  Future<bool> scheduleTrialReminder({
    required DateTime due,
    required String title,
    required String body,
  }) async {
    if (!enabled) return false;
    armedFor = due;
    return true;
  }

  @override
  Future<void> cancelTrialReminder() async => cancels++;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of this test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late _FakeNotifications notifications;

  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    notifications = _FakeNotifications();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('who gets remembered', () {
    test('a trial abandonment is written down and shows the row', () async {
      final c = await container();
      await c
          .read(trialNudgeProvider.notifier)
          .remember('DKS_S_1', trialAttempt: true);

      expect(c.read(trialNudgeProvider), isTrue);
      expect(prefs.getString(TrialNudge.orderKey), 'DKS_S_1');
      expect(prefs.getInt(TrialNudge.markerKey), isNotNull);
    });

    test('a SPENT-trial abandonment is not — the line would promise a trial '
        'that no longer exists', () async {
      final c = await container();
      await c
          .read(trialNudgeProvider.notifier)
          .remember('DKS_S_2', trialAttempt: false);

      expect(c.read(trialNudgeProvider), isFalse);
      expect(prefs.getInt(TrialNudge.markerKey), isNull);
      expect(notifications.armedFor, isNull, reason: 'and no reminder either');
    });

    test('a settled purchase forgets it and drops the reminder', () async {
      final c = await container();
      await c
          .read(trialNudgeProvider.notifier)
          .remember('DKS_S_3', trialAttempt: true);
      await c.read(trialNudgeProvider.notifier).resolve();

      expect(c.read(trialNudgeProvider), isFalse);
      expect(prefs.getInt(TrialNudge.markerKey), isNull);
      expect(prefs.getInt(TrialNudge.reminderDueKey), isNull);
      expect(notifications.cancels, 1);
    });

    test('dismissing hides the row but KEEPS the marker — declined now, not '
        'declined for good', () async {
      final c = await container();
      await c
          .read(trialNudgeProvider.notifier)
          .remember('DKS_S_4', trialAttempt: true);
      c.read(trialNudgeProvider.notifier).dismiss();

      expect(c.read(trialNudgeProvider), isFalse);
      expect(prefs.getInt(TrialNudge.markerKey), isNotNull);
    });
  });

  group('the reminder', () {
    test(
      'is armed, and its instant is persisted for the launch re-arm',
      () async {
        final c = await container();
        await c
            .read(trialNudgeProvider.notifier)
            .remember('DKS_S_5', trialAttempt: true);

        expect(notifications.armedFor, isNotNull);
        expect(
          prefs.getInt(TrialNudge.reminderDueKey),
          notifications.armedFor!.millisecondsSinceEpoch,
        );
      },
    );

    test('is NOT armed when notifications are off, and then no instant is '
        'persisted — the launch re-arm must not resurrect one', () async {
      final c = await container();
      notifications.enabled = false;
      await c
          .read(trialNudgeProvider.notifier)
          .remember('DKS_S_6', trialAttempt: true);

      expect(notifications.armedFor, isNull);
      expect(prefs.getInt(TrialNudge.reminderDueKey), isNull);
      // The row still carries it — that half never needed a permission.
      expect(c.read(trialNudgeProvider), isTrue);
    });
  });

  group('TrialNudge.reminderTime', () {
    DateTime at(int hour, [int minute = 0]) =>
        DateTime(2026, 9, 11, hour, minute);

    test('six hours later, when that lands in waking hours', () {
      expect(TrialNudge.reminderTime(at(10)), at(16));
      expect(TrialNudge.reminderTime(at(14, 30)), at(20, 30));
    });

    test('an early-hours landing waits for the SAME morning', () {
      // 02:00 + 6h = 08:00, one hour early.
      expect(TrialNudge.reminderTime(at(2)), at(9));
    });

    test('a late-night landing waits for the NEXT morning — a notification '
        'about money at 03:00 is a reason to uninstall', () {
      // 22:00 + 6h = 04:00 tomorrow.
      expect(TrialNudge.reminderTime(at(22)), DateTime(2026, 9, 12, 9));
      // 16:00 + 6h = 22:00, past the cutoff.
      expect(TrialNudge.reminderTime(at(16)), DateTime(2026, 9, 12, 9));
    });

    test('20:59 still goes out tonight; 21:00 does not', () {
      expect(TrialNudge.reminderTime(at(14, 59)), at(20, 59));
      expect(TrialNudge.reminderTime(at(15)), DateTime(2026, 9, 12, 9));
    });
  });

  group('TrialNudge.isLive', () {
    test('a marker inside the window shows', () async {
      await container();
      await prefs.setInt(
        TrialNudge.markerKey,
        DateTime(2026, 9, 11).millisecondsSinceEpoch,
      );
      expect(TrialNudge.isLive(prefs, DateTime(2026, 9, 17)), isTrue);
    });

    test('a marker past the window does not — the moment has gone', () async {
      await container();
      await prefs.setInt(
        TrialNudge.markerKey,
        DateTime(2026, 9, 11).millisecondsSinceEpoch,
      );
      expect(TrialNudge.isLive(prefs, DateTime(2026, 9, 19)), isFalse);
    });

    test('no marker, no row', () async {
      await container();
      expect(TrialNudge.isLive(prefs, DateTime.now()), isFalse);
    });
  });

  group('TrialNudge.pendingReminder', () {
    test('a future instant is re-armable', () async {
      await container();
      final due = DateTime(2026, 9, 11, 18);
      await prefs.setInt(TrialNudge.reminderDueKey, due.millisecondsSinceEpoch);
      expect(TrialNudge.pendingReminder(prefs, DateTime(2026, 9, 11, 12)), due);
    });

    test('an instant already past is not — a reminder that missed its moment '
        'must not fire on the next launch instead', () async {
      await container();
      await prefs.setInt(
        TrialNudge.reminderDueKey,
        DateTime(2026, 9, 11, 18).millisecondsSinceEpoch,
      );
      expect(
        TrialNudge.pendingReminder(prefs, DateTime(2026, 9, 12, 9)),
        isNull,
      );
    });
  });
}
