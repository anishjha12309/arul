import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/analytics/analytics_provider.dart';
import '../../../core/error/app_exception.dart';
import '../../../data/models/ringtone.dart';
import '../../auth/providers/auth_providers.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/ringtone_set_service.dart';

// ─── Stage & state ────────────────────────────────────────────────────────────

/// Stages reported while setting a ringtone.
enum RingtoneSetStage { checkingPermission, fetchingUrl, downloading, setting }

/// State machine for setting a ringtone: idle → loading (per [RingtoneSetStage])
/// → success | error. Ported from the reference.
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

final class RingtoneSetSuccess extends RingtoneSetState {
  const RingtoneSetSuccess({required this.target});
  final RingtoneTarget target;
}

final class RingtoneSetError extends RingtoneSetState {
  const RingtoneSetError({
    required this.message,
    this.isNetwork = false,
    this.premiumRequired = false,
  });
  final String message;

  /// True when the failure was a connectivity error, so the UI can show a
  /// friendly "no internet" message instead of the raw exception text.
  final bool isNetwork;

  /// The server refused because the subscription is no longer live — the
  /// screen routes to the paywall instead of toasting a generic failure.
  final bool premiumRequired;
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
    // Re-entrancy guard, same as apply/share.
    if (state is RingtoneSetLoading) {
      return;
    }

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
        // Straight to Android's "Modify system settings" grant screen — no
        // in-app explainer in front of it (owner, 2026-08-21). The user grants
        // it there, comes back and taps Set again; nothing is parked here.
        await service.openWriteSettings();
        state = const RingtoneSetIdle();
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
      // Named by catalog id — a stable cache key, never shown to the user; the
      // human-visible tone name is `ringtone.title`, threaded to the native
      // MediaStore insert below.
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

      await service.setRingtone(
        file,
        target,
        title: ringtone.title,
        mime: ringtone.mime ?? 'audio/mpeg',
      );

      analytics.track(
        'ringtone_set',
        properties: {'ringtone_id': ringtone.id, 'category': ringtone.category},
      );

      state = RingtoneSetSuccess(target: target);
    } on RingtoneSetException catch (e) {
      if (e.premiumRequired) {
        // The client snapshot that let this through is stale — refresh it so
        // the paywall the screen opens shows the real state.
        ref.invalidate(entitlementDetailProvider);
      }
      state = RingtoneSetError(
        message: e.message,
        premiumRequired: e.premiumRequired,
      );
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
}

// ─── Provider ─────────────────────────────────────────────────────────────────

final ringtoneSetProvider =
    NotifierProvider<RingtoneSetNotifier, RingtoneSetState>(
      RingtoneSetNotifier.new,
    );
