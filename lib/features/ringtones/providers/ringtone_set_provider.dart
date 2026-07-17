import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/error/app_exception.dart';
import '../../../data/models/ringtone.dart';
import '../../auth/providers/auth_providers.dart';
import '../data/ringtone_set_service.dart';

// ─── Stage & state ────────────────────────────────────────────────────────────

/// Stages reported while setting a ringtone.
enum RingtoneSetStage { checkingPermission, fetchingUrl, downloading, setting }

/// State machine for setting a ringtone: idle → loading (per [RingtoneSetStage])
/// → needs-permission | success | error. Ported from the reference.
sealed class RingtoneSetState {
  const RingtoneSetState();
}

final class RingtoneSetIdle extends RingtoneSetState {
  const RingtoneSetIdle();
}

final class RingtoneSetLoading extends RingtoneSetState {
  const RingtoneSetLoading({
    required this.ringtoneId,
    required this.stage,
    this.progress,
  });

  /// ID of the ringtone being set — cards use this to show a spinner only for
  /// themselves.
  final String ringtoneId;
  final RingtoneSetStage stage;

  /// Download progress 0.0–1.0; null for non-download stages.
  final double? progress;
}

/// Emitted when `WRITE_SETTINGS` is not granted. The screen shows an
/// explanation sheet with an "Open settings" CTA.
final class RingtoneSetNeedsPermission extends RingtoneSetState {
  const RingtoneSetNeedsPermission();
}

final class RingtoneSetSuccess extends RingtoneSetState {
  const RingtoneSetSuccess({required this.target});
  final RingtoneTarget target;
}

final class RingtoneSetError extends RingtoneSetState {
  const RingtoneSetError({required this.message, this.isNetwork = false});
  final String message;

  /// True when the failure was a connectivity error, so the UI can show a
  /// friendly "no internet" message instead of the raw exception text.
  final bool isNetwork;
}

// ─── Service provider ─────────────────────────────────────────────────────────

final ringtoneSetServiceProvider = Provider<RingtoneSetService>((ref) {
  return AndroidRingtoneSetService(
    apiClient: ref.watch(apiClientProvider),
    httpClient: http.Client(),
  );
});

// ─── Notifier ─────────────────────────────────────────────────────────────────

/// Orchestrates setting a ringtone: permission check → signed URL (the Worker's
/// LIVE entitlement check — the real premium gate) → download → MediaStore
/// register + set as the device tone.
class RingtoneSetNotifier extends Notifier<RingtoneSetState> {
  @override
  RingtoneSetState build() => const RingtoneSetIdle();

  /// Sets [ringtone] as the [target] tone, walking the permission → fetch →
  /// download → set pipeline (see [RingtoneSetStage]).
  Future<void> setRingtone(Ringtone ringtone, RingtoneTarget target) async {
    final service = ref.read(ringtoneSetServiceProvider);
    final analytics = ref.read(analyticsServiceProvider);

    try {
      // 1. Check WRITE_SETTINGS permission
      state = RingtoneSetLoading(
        ringtoneId: ringtone.id,
        stage: RingtoneSetStage.checkingPermission,
      );
      final canWrite = await service.canWriteSettings();
      if (!canWrite) {
        state = const RingtoneSetNeedsPermission();
        return;
      }

      // 2. Fetch short-lived signed R2 URL via Worker
      state = RingtoneSetLoading(
        ringtoneId: ringtone.id,
        stage: RingtoneSetStage.fetchingUrl,
      );
      final signedUrl = await service.fetchSignedUrl(ringtone.id);

      // 3. Download file with progress
      state = RingtoneSetLoading(
        ringtoneId: ringtone.id,
        stage: RingtoneSetStage.downloading,
        progress: 0.0,
      );
      final ext = ringtone.mime == 'audio/mpeg' ? 'mp3' : 'aac';
      final filename = '${ringtone.id}.$ext';
      final file = await service.downloadFile(signedUrl, filename, (p) {
        state = RingtoneSetLoading(
          ringtoneId: ringtone.id,
          stage: RingtoneSetStage.downloading,
          progress: p,
        );
      });

      // 4. Register in MediaStore and set as device tone
      state = RingtoneSetLoading(
        ringtoneId: ringtone.id,
        stage: RingtoneSetStage.setting,
      );

      analytics.track(
        'ringtone_set_attempt',
        properties: {'ringtone_id': ringtone.id, 'category': ringtone.category},
      );

      await service.setRingtone(file, target);

      analytics.track(
        'ringtone_set',
        properties: {'ringtone_id': ringtone.id, 'category': ringtone.category},
      );

      state = RingtoneSetSuccess(target: target);
    } on RingtoneSetException catch (e) {
      state = RingtoneSetError(message: e.message);
    } catch (e) {
      // The signed-URL POST and the download throw raw connectivity errors when
      // offline — flag them so the screen shows a friendly message.
      state = RingtoneSetError(
        message: e.toString(),
        isNetwork: isNetworkError(e),
      );
    }
  }

  void reset() => state = const RingtoneSetIdle();

  /// Open system settings for WRITE_SETTINGS and reset state so the user can
  /// retry after granting the permission.
  Future<void> openWriteSettings() async {
    await ref.read(ringtoneSetServiceProvider).openWriteSettings();
    reset();
  }
}

// ─── Provider ─────────────────────────────────────────────────────────────────

final ringtoneSetProvider =
    NotifierProvider<RingtoneSetNotifier, RingtoneSetState>(
      RingtoneSetNotifier.new,
    );
