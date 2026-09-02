import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/build_info.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../theme/arul_tokens.dart';
import '../domain/devotional_event.dart';
import '../providers/notification_providers.dart';

/// Settings sub-screen for devotional reminders — one master switch plus the time they fire.
/// Accepting it enables the WHOLE set, the weekly day and every festival; no per-festival opt-ins.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The OS permission can diverge from the persisted opt-in — revoked, or granted on one install.
    // Reconcile on open -> the toggle never shows an opt-in Android is quietly blocking.
    ref.read(notificationSettingsProvider.notifier).syncWithSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check when the user comes back from system settings mid-session.
    if (state == AppLifecycleState.resumed) {
      ref.read(notificationSettingsProvider.notifier).syncWithSystem();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? ArulTokens.darkSurface : ArulTokens.ivory;
    final headerColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    final settings = ref.watch(notificationSettingsProvider);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Same header block as Settings, so the two read as one surface.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (context.canPop()) context.pop();
                    },
                    child: Icon(Icons.arrow_back, size: 24, color: headerColor),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.remindersTitle,
                    style: ArulTokens.screenTitle.copyWith(color: headerColor),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _Card(
                    child: _ToggleRow(
                      icon: Icons.notifications_active_rounded,
                      title: l10n.remindersToggleTitle,
                      sub: l10n.remindersToggleSub,
                      value: settings.masterEnabled,
                      onChanged: _onMasterChanged,
                    ),
                  ),

                  // One reminder time is the ONLY other control — turning it on turns on the set.
                  if (settings.masterEnabled) ...[
                    const SizedBox(height: ArulTokens.contentGap),
                    _Card(
                      child: _TimeRow(
                        hour: settings.reminderHour,
                        minute: settings.reminderMinute,
                        onPick: (h, m) => ref
                            .read(notificationSettingsProvider.notifier)
                            .setReminderTime(h, m),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      // Says what arrives and roughly how often -> the opt-in is informed.
                      // Vague about dates on purpose — festival reminders fire early, never name one.
                      child: Text(
                        l10n.remindersScheduleNote,
                        style: ArulTokens.rowSub.copyWith(
                          color: subColor,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: ArulTokens.contentGap),
                    _Card(child: _WhatYoullGet(festivals: festivalEvents)),
                  ],

                  // Debug AND sideloaded release APK; never the Play build.
                  // R8 stripping icons, a stale channel sound, an alarm never armed happen in RELEASE.
                  // So the gate is deliberately NOT kDebugMode — such a tool could never catch them.
                  if (ref.watch(qaToolsEnabledProvider)) ...[
                    const SizedBox(height: ArulTokens.contentGap),
                    _QaTools(
                      onTest: _sendTest,
                      onPreviewAll: _previewAll,
                      onAudit: _audit,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMasterChanged(bool value) async {
    ArulHaptics.selection();
    final l10n = AppLocalizations.of(context);
    final granted = await ref
        .read(notificationSettingsProvider.notifier)
        .setMasterEnabled(value);
    if (!mounted) return;
    if (value && !granted) {
      showArulToast(context, l10n.remindersPermissionToast);
    }
  }

  Future<void> _sendTest() async {
    await ref.read(notificationServiceProvider).scheduleTestNotification();
    if (!mounted) return;
    showArulToast(context, 'Test scheduled — minimise Arul to see it.');
  }

  Future<void> _previewAll() async {
    try {
      await ref.read(notificationServiceProvider).previewAll();
      if (!mounted) return;
      showArulToast(
        context,
        'Fired ${weeklyDevotionalDays.length + festivalEvents.length} — check '
        'the shade for icons, copy and sound.',
      );
    } catch (e) {
      if (!mounted) return;
      showArulToast(context, 'Preview failed: $e', kind: ToastKind.error);
    }
  }

  /// Reads back what is ACTUALLY armed with the OS — the only check that can fail invisibly.
  Future<void> _audit() async {
    try {
      final audit = await ref.read(notificationServiceProvider).audit();
      if (!mounted) return;
      if (audit.totalArmed == 0) {
        showArulToast(
          context,
          'Nothing armed. Turn reminders on first.',
          kind: ToastKind.error,
        );
        return;
      }
      final skipped = audit.skippedFestivals;
      showArulToast(
        context,
        '${audit.totalArmed} armed — ${audit.weeklyArmed}/'
        '${audit.weeklyExpected} weekly, ${audit.festivalsArmed}/'
        '${audit.festivalsExpected} festivals'
        '${skipped > 0 ? ' · $skipped skipped (table ran out)' : ''}',
        kind: audit.complete ? ToastKind.success : ToastKind.info,
      );
    } catch (e) {
      if (!mounted) return;
      showArulToast(context, 'Audit failed: $e', kind: ToastKind.error);
    }
  }
}

/// The same rounded, hairline-bordered surface Settings uses for its rows card.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? ArulTokens.cardBgDark04 : ArulTokens.cardBgLight,
        border: Border.all(
          color: isDark
              ? ArulTokens.cardBorderDark09
              : ArulTokens.cardBorderLight,
        ),
        borderRadius: BorderRadius.circular(ArulTokens.rowsCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Icon chip + title/subtitle + switch, matching the Settings row metrics.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final chipBg = isDark
        ? ArulTokens.goldTintFill10
        : ArulTokens.maroonTintFill07;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: ArulTokens.iconChipSize,
            height: ArulTokens.iconChipSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: chipBg,
              borderRadius: BorderRadius.circular(ArulTokens.iconChipRadius),
            ),
            child: Icon(icon, size: ArulTokens.iconChipIconSize, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: ArulTokens.rowTitle.copyWith(color: titleColor),
                ),
                const SizedBox(height: 1),
                Text(sub, style: ArulTokens.rowSub.copyWith(color: subColor)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: accent,
          ),
        ],
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.hour,
    required this.minute,
    required this.onPick,
  });

  final int hour;
  final int minute;
  final void Function(int hour, int minute) onPick;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final time = TimeOfDay(hour: hour, minute: minute);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        ArulHaptics.tap();
        final picked = await showTimePicker(
          context: context,
          initialTime: time,
        );
        if (picked != null) onPick(picked.hour, picked.minute);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Icon(Icons.schedule_rounded, size: 20, color: accent),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                AppLocalizations.of(context).remindersTimeLabel,
                style: ArulTokens.rowTitle.copyWith(color: titleColor),
              ),
            ),
            Text(
              time.format(context),
              style: ArulTokens.rowTitle.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The next few festivals, named — a switch alone asks the user to take the value on faith.
///
/// Shows only what the table can back: a festival out of dates is skipped exactly as the scheduler
/// skips it, so the list can never advertise a reminder that will not arrive.
class _WhatYoullGet extends StatelessWidget {
  const _WhatYoullGet({required this.festivals});

  final List<FestivalEvent> festivals;

  /// Enough to convey the rhythm without turning into a calendar.
  static const _max = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? ArulTokens.darkText : ArulTokens.lightText;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    final now = DateTime.now();
    final upcoming =
        festivals
            .map((f) => (event: f, date: f.nextOccurrenceAfter(now)))
            .where((e) => e.date != null)
            .toList()
          ..sort((a, b) => a.date!.compareTo(b.date!));

    if (upcoming.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.remindersComingUp,
            style: ArulTokens.rowSub.copyWith(
              color: subColor,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          for (final e in upcoming.take(_max))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(e.event.emoji, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      e.event.title,
                      style: ArulTokens.rowTitle.copyWith(color: titleColor),
                    ),
                  ),
                  Text(
                    _monthDay(l10n, e.date!),
                    style: ArulTokens.rowSub.copyWith(color: subColor),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _month(AppLocalizations l10n, int month) => switch (month) {
    1 => l10n.remindersMonthJan,
    2 => l10n.remindersMonthFeb,
    3 => l10n.remindersMonthMar,
    4 => l10n.remindersMonthApr,
    5 => l10n.remindersMonthMay,
    6 => l10n.remindersMonthJun,
    7 => l10n.remindersMonthJul,
    8 => l10n.remindersMonthAug,
    9 => l10n.remindersMonthSep,
    10 => l10n.remindersMonthOct,
    11 => l10n.remindersMonthNov,
    _ => l10n.remindersMonthDec,
  };

  static String _monthDay(AppLocalizations l10n, DateTime d) =>
      '${_month(l10n, d.month)} ${d.day}';
}

/// On-device QA for the reminder system — debug and sideloaded release APK, never Play.
///
/// Three checks, each answering something the others cannot:
///  * **Send a test** — does a notification reach the shade at all (permission, channel, OEM policy);
///  * **Preview all** — do the real icons, copy, accent and sound render? Catches R8 having stripped
///    `ic_notification`, which only ever happens in a release build;
///  * **What's armed** — did the alarms actually get scheduled? One that looks perfect and never
///    armed is indistinguishable from a working one until the day it does not arrive.
class _QaTools extends StatelessWidget {
  const _QaTools({
    required this.onTest,
    required this.onPreviewAll,
    required this.onAudit,
  });

  final Future<void> Function() onTest;
  final Future<void> Function() onPreviewAll;
  final Future<void> Function() onAudit;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? ArulTokens.gold : ArulTokens.maroon;
    final subColor = isDark
        ? ArulTokens.darkTextSecondary
        : ArulTokens.lightSecondary;

    Widget button(String label, Future<void> Function() onPressed) =>
        OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: BorderSide(color: accent.withValues(alpha: 0.5)),
          ),
          child: Text(label),
        );

    return _Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'TESTING',
              style: ArulTokens.rowSub.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Not shown in the Play build. Minimise Arul after tapping — '
              'Android suppresses notifications for the app in the foreground.',
              style: ArulTokens.rowSub.copyWith(color: subColor, height: 1.4),
            ),
            const SizedBox(height: 12),
            button('Send a test notification', onTest),
            const SizedBox(height: 8),
            button('Preview every reminder', onPreviewAll),
            const SizedBox(height: 8),
            button("What's armed right now", onAudit),
          ],
        ),
      ),
    );
  }
}
