import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Cached for the session, re-fetched only after [invalidate] -> one paginated drain stamps EVERY
/// page with the same `?v`, so a slow network cannot mix two versions mid-drain.
/// On any failure keep the last known version (or null -> no `?v`) -> the CDN-only,
/// no-DB-fallback contract holds. See docs/architecture.md.
class CatalogVersion {
  CatalogVersion({required this.cdnBaseUrl, http.Client? client})
    : _client = client ?? http.Client();

  final String cdnBaseUrl;
  final http.Client _client;

  String? _cached;
  bool _dirty = true;

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
    }
    return _cached;
  }

  void invalidate() => _dirty = true;
}
