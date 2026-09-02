import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Resolves the current catalog content version from the always-fresh
/// `catalog/version.json` pointer (served `no-store` by build-catalog).
///
/// Callers append `?v=<version>` to every catalog/app_config fetch -> a publish changes the version
/// and so the edge-cache key -> new content lands at once while the bodies stay cacheable.
/// Cached for the session, re-fetched only after [invalidate] -> one paginated drain stamps EVERY
/// page with the same `?v`, so a slow network cannot mix two versions mid-drain.
/// [invalidate] runs on explicit pull-to-refresh -> that read is authoritative and picks up a
/// just-published version.
/// On any failure keep the last known version (or null -> no `?v`) -> the CDN-only,
/// no-DB-fallback contract holds. See docs/architecture.md.
class CatalogVersion {
  CatalogVersion({required this.cdnBaseUrl, http.Client? client})
    : _client = client ?? http.Client();

  final String cdnBaseUrl;
  final http.Client _client;

  String? _cached;
  bool _dirty = true; // re-fetch on first use and after invalidate()

  /// The current version string, or null if unknown (pre first build / offline).
  Future<String?> current() async {
    if (!_dirty && _cached != null) return _cached;
    try {
      final url = Uri.parse('$cdnBaseUrl/catalog/version.json');
      final res = await _client
          .get(url, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final v = json['content_version'];
        _cached = v?.toString();
        _dirty = false;
      }
    } catch (e) {
      debugPrint('[CatalogVersion] version.json fetch failed: $e');
      // Keep the last known version (may be null) -> callers simply omit ?v.
    }
    return _cached;
  }

  /// Force the next [current] call to re-fetch (e.g. on explicit pull-to-refresh).
  void invalidate() => _dirty = true;
}
