import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/analytics/analytics_events.dart';
import '../../../core/analytics/analytics_provider.dart';
import '../../../core/error/app_exception.dart';
import '../../../data/models/ringtone.dart';
import '../../auth/providers/auth_providers.dart';
import '../../premium/providers/entitlement_provider.dart';
import '../data/ringtone_set_service.dart';

/// Stages reported while setting a ringtone.
enum RingtoneSetStage { checkingPermission, fetchingUrl, downloading, setting }

/// State machine for setting a ringtone: idle → loading, per [RingtoneSetStage] → success or error.
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

  /// ID of the ringtone being set — cards use it to spin only for themselves.
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

  /// True for a connectivity error -> the UI shows "no internet", never the raw exception text.
  final bool isNetwork;

  /// The server refused because the subscription is no longer live -> route to the paywall, not a toast.
  final bool premiumRequired;
}

final ringtoneSetServiceProvider = Provider<RingtoneSetService>((ref) {
  return AndroidRingtoneSetService(
    apiClient: ref.watch(apiClientProvider),
    httpClient: http.Client(),
  );
});

/// Orchestrates setting a ringtone: permission check → signed URL → download → MediaStore + set.
/// The signed-URL call is the Worker's LIVE entitlement check — the real premium gate.
class RingtoneSetNotifier extends Notifier<RingtoneSetState> {
  /// The set interrupted by Android's grant screen, resumed when the app returns holding it.
  ({Ringtone ringtone, RingtoneTarget target})? _parkedForGrant;
  AppLifecycleListener? _grantReturnListener;

  @override
  RingtoneSetState build() {
    ref.onDispose(_dropParkedSet);
    return const RingtoneSetIdle();
  }

  /// Sets [ringtone] as the [target] tone, walking the [RingtoneSetStage] pipeline.
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
        // Straight to Android's grant screen — NO in-app explainer in front of it (owner's call).
        // The request is PARKED and finishes itself when the app resumes holding the permission.
        // Making the user tap Set again read as "I granted it and nothing happened".
        // A resume WITHOUT the grant just drops it.
        _parkedForGrant = (ringtone: ringtone, target: target);
        _grantReturnListener ??= AppLifecycleListener(
          onStateChange: (lifecycle) {
            if (lifecycle == AppLifecycleState.resumed) {
              unawaited(_resumeParkedSet());
            }
          },
        );
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
      // Named by catalog id — a stable cache key, never shown to the user.
      // The human-visible tone name is `ringtone.title`, threaded to the MediaStore insert below.
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
        ArulEvents.ringtoneSet,
        properties: {'ringtone_id': ringtone.id, 'category': ringtone.category},
      );

      state = RingtoneSetSuccess(target: target);
    } on RingtoneSetException catch (e) {
      if (e.premiumRequired) {
        // The client snapshot that let this through is stale -> refresh, so the paywall reads true.
        ref.invalidate(entitlementDetailProvider);
      }
      state = RingtoneSetError(
        message: e.message,
        premiumRequired: e.premiumRequired,
      );
    } catch (e) {
      // The signed-URL POST and the download throw raw connectivity errors offline -> flag them.
      state = RingtoneSetError(
        message: e.toString(),
        isNetwork: isNetworkError(e),
      );
    }
  }

  /// Runs the parked set ONCE, on the first resume after the grant screen, if the permission is held.
  /// The lifecycle listener is one-shot and gone before the pipeline starts -> no resume can replay it.
  Future<void> _resumeParkedSet() async {
    final parked = _parkedForGrant;
    _dropParkedSet();
    if (parked == null) return;
    final canWrite = await ref
        .read(ringtoneSetServiceProvider)
        .canWriteSettings();
    if (!canWrite) return;
    await setRingtone(parked.ringtone, parked.target);
  }

  void _dropParkedSet() {
    _parkedForGrant = null;
    _grantReturnListener?.dispose();
    _grantReturnListener = null;
  }

  void reset() => state = const RingtoneSetIdle();
}

final ringtoneSetProvider =
    NotifierProvider<RingtoneSetNotifier, RingtoneSetState>(
      RingtoneSetNotifier.new,
    );
