import '../../../data/models/app_config_model.dart';

/// Read access to the remote app configuration.
abstract interface class AppConfigRepository {
  /// Returns the singleton app_config row, or null if not yet seeded.
  Future<AppConfigModel?> getAppConfig();
}
