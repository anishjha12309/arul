import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/install_referrer_service.dart';
import '../domain/referral_summary.dart';

part 'referral_providers.g.dart';

/// Play Install Referrer capture + pending-code handoff to sign-in.
@Riverpod(keepAlive: true)
InstallReferrerService installReferrerService(Ref ref) =>
    InstallReferrerService(ref.watch(sharedPreferencesProvider));

/// The Refer & Earn screen's data: own code + referrals + total days earned.
/// `ref.invalidate(referralSummaryProvider)` re-fetches (pull-to-refresh / the
/// app-bar refresh button).
@riverpod
Future<ReferralSummary> referralSummary(Ref ref) =>
    ref.watch(referralRepositoryProvider).getReferralSummary();
