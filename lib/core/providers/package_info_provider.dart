import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'package_info_provider.g.dart';

/// Loads the platform [PackageInfo] once and caches it. Used for the real
/// app version in the support-email diagnostics block.
@Riverpod(keepAlive: true)
Future<PackageInfo> packageInfo(Ref ref) => PackageInfo.fromPlatform();
