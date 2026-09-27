import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/error/app_exception.dart';
import '../models/catalog_page.dart';
import 'catalog_version.dart';

/// Fetches a paginated catalog JSON page from the CDN.
/// A non-200 *response* (cache miss, 404 past the last page) or a parse failure returns null -> the
/// caller renders an empty page. CDN-only: there is no DB fallback.
/// A connectivity failure (offline / host unreachable / timeout) is NOT a CDN miss -> it throws
/// [NetworkException] so the feed can tell "no internet" from "no content" and offer a retry.
class CatalogHttpClient {
  CatalogHttpClient({
    required this.cdnBaseUrl,
    http.Client? client,
    this.version,
  }) : _client = client ?? http.Client();

  final String cdnBaseUrl;

  final CatalogVersion? version;

  final http.Client _client;

  Future<CatalogPage<T>?> fetchPage<T>({
    required String scope,
    required String slug,
    required int page,
    required T Function(Map<String, dynamic>) itemFromJson,
  }) async {
    final v = await version?.current();
    final base = '$cdnBaseUrl/catalog/$scope/${slug}_$page.json';
    final url = Uri.parse(v != null && v.isNotEmpty ? '$base?v=$v' : base);
    try {
      final response = await _client
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('[CatalogHttpClient] $url → ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return CatalogPage.fromJson(json, itemFromJson);
    } catch (e) {
      if (isNetworkError(e)) {
        debugPrint('[CatalogHttpClient] network error for $url: $e');
        throw const NetworkException();
      }
      debugPrint('[CatalogHttpClient] fetch failed for $url: $e');
      return null;
    }
  }
}
