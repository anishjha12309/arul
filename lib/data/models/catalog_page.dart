/// Paginated response from the edge-cached CDN catalog.
/// Plain Dart class (not freezed) because generic fromJson requires
/// a caller-supplied item parser.
class CatalogPage<T> {
  const CatalogPage({
    required this.items,
    required this.page,
    required this.perPage,
    required this.total,
    required this.totalPages,
    required this.hasMore,
  });

  final List<T> items;
  final int page;
  final int perPage;
  final int total;
  final int totalPages;
  final bool hasMore;

  static CatalogPage<T> fromJson<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) {
    final rawItems = json['items'] as List<dynamic>? ?? [];
    return CatalogPage<T>(
      items: rawItems
          .map((e) => itemFromJson(e as Map<String, dynamic>))
          .toList(),
      page: (json['page'] as num?)?.toInt() ?? 1,
      perPage: (json['per_page'] as num?)?.toInt() ?? 20,
      total: (json['total'] as num?)?.toInt() ?? rawItems.length,
      totalPages: (json['total_pages'] as num?)?.toInt() ?? 1,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'CatalogPage(page: $page/$totalPages, items: ${items.length}, total: $total)';
}
