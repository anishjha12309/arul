import '../../../data/models/app_config_model.dart';

abstract interface class AppConfigRepository {
  Future<AppConfigModel?> getAppConfig();
}
