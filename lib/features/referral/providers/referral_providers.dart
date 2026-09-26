import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/shared_preferences_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../data/install_referrer_service.dart';
import '../domain/referral_summary.dart';

part 'referral_providers.g.dart';

@Riverpod(keepAlive: true)
InstallReferrerService installReferrerService(Ref ref) =>
    InstallReferrerService(ref.watch(sharedPreferencesProvider));

@riverpod
Future<ReferralSummary> referralSummary(Ref ref) =>
    ref.watch(referralRepositoryProvider).getReferralSummary();
