import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../data/catalog/catalog_version.dart';
import '../../../data/models/app_config_model.dart';
import '../domain/app_config_repository.dart';

/// Reads app_config from a public CDN JSON file (preferred — no auth, free
/// egress, cached at the edge).  Falls back to a Worker GET if the CDN file
/// is absent (e.g. before the first build-catalog run).
///
/// When a [CatalogVersion] is provided, the fetch is version-stamped with `?v=`
/// so a republished app_config propagates near-instantly (see CatalogVersion).
class ApiAppConfigRepository implements AppConfigRepository {
  ApiAppConfigRepository({this.version});

  /// Optional version resolver; when set, the fetch is stamped with `?v=`.
  final CatalogVersion? version;

  @override
  Future<AppConfigModel?> getAppConfig() async {
    // Primary: public CDN JSON baked by the build-catalog Worker.
    final v = await version?.current();
    final base = '${AppConfig.cdnBaseUrl}/catalog/app_config.json';
    final cdnUrl = Uri.parse(v != null && v.isNotEmpty ? '$base?v=$v' : base);
    try {
      final response = await http
          .get(cdnUrl, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return AppConfigModel.fromJson(json);
      }
    } catch (e) {
      debugPrint('[ApiAppConfigRepository] CDN fetch failed: $e');
    }

    // No Worker fallback route — catalog/app_config.json (build-catalog, §4) is
    // the source; returns null only if the CDN file is absent (pre first build).
    return null;
  }
}
