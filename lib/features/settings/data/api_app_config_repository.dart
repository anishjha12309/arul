import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../data/catalog/catalog_version.dart';
import '../../../data/models/app_config_model.dart';
import '../domain/app_config_repository.dart';

/// Reads app_config from a public CDN JSON file — no auth, free egress, cached at the edge.
/// Null before the first build-catalog run leaves the file absent.
/// A [CatalogVersion] stamps the fetch with `?v=` -> a republished app_config propagates at once.
class ApiAppConfigRepository implements AppConfigRepository {
  ApiAppConfigRepository({this.version});

  /// Optional version resolver; when set, the fetch is stamped with `?v=`.
  final CatalogVersion? version;

  @override
  Future<AppConfigModel?> getAppConfig() async {
    // Public CDN JSON, baked by the build-catalog Worker.
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

    // NO Worker fallback route — catalog/app_config.json is the source (CLAUDE.md §4).
    // Null only when the CDN file is absent, i.e. before the first build.
    return null;
  }
}
