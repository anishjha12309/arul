import '../../../data/catalog/catalog_http_client.dart';
import '../../../data/models/catalog_page.dart';
import '../../../data/models/ringtone.dart';
import '../domain/ringtone_repository.dart';

/// Reads the ringtone catalog from the edge-cached CDN JSON
/// (`catalog/ringtones/all_{page}.json`).
class CdnRingtoneRepository implements RingtoneRepository {
  const CdnRingtoneRepository({required this.catalogClient});

  final CatalogHttpClient catalogClient;

  @override
  Future<CatalogPage<Ringtone>> getRingtones({int page = 1}) async {
    // Category is THE browse axis but filtering is client-side over the drained list -> only ever
    // fetch the shared "all" catalog.
    final cdnPage = await catalogClient.fetchPage(
      scope: 'ringtones',
      slug: 'all',
      page: page,
      itemFromJson: Ringtone.fromJson,
    );

    if (cdnPage != null) return cdnPage;

    // The build always writes page 1 even for a zero-row scope (architecture.md §Catalog
    // generation) -> a miss means the build failed upstream, not that there are no ringtones.
    // Degrade to the empty state, never a DB fallback.
    return CatalogPage<Ringtone>(
      items: const [],
      page: page,
      perPage: 20,
      total: 0,
      totalPages: 0,
      hasMore: false,
    );
  }
}
