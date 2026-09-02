import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/error/app_exception.dart';
import '../models/catalog_page.dart';
import 'catalog_version.dart';

/// Fetches a paginated catalog JSON page from the CDN.
///
/// Key format `catalog/{scope}/{slug}_{page}.json` — [scope] is `wallpapers` or `ringtones`, [slug]
/// a tag name or `all`.
/// A [CatalogVersion] appends `?v=<version>` -> a freshly-published catalog is a new edge-cache key
/// -> near-instant updates; the stamp is omitted when the version is unknown.
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

  /// Optional version resolver; when set, fetches are version-stamped with `?v=`.
  final CatalogVersion? version;

  // A single long-lived client so the connection pool reuses one TCP/TLS
  // session across calls. This matters for the filtered-feed drain, which
  // fetches every catalog page sequentially — the top-level `http.get` would
  // otherwise open (and tear down) a fresh socket per page.
  final http.Client _client;

  /// Returns a parsed [CatalogPage], null on a cache miss / non-200 / parse
  /// failure, or throws [NetworkException] when the device can't reach the CDN.
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
      // Offline / unreachable host / timed-out socket → surface as a network
      // error so the feed shows "check your internet" + retry. A parse error or
      // any other non-connectivity failure stays a silent miss (null).
      if (isNetworkError(e)) {
        debugPrint('[CatalogHttpClient] network error for $url: $e');
        throw const NetworkException();
      }
      debugPrint('[CatalogHttpClient] fetch failed for $url: $e');
      return null;
    }
  }
}
