import '../../../data/catalog/catalog_http_client.dart';
import '../../../data/models/catalog_page.dart';
import '../../../data/models/ringtone.dart';
import '../domain/ringtone_repository.dart';

/// Reads the ringtone catalog from the edge-cached CDN JSON
/// (`catalog/ringtones/all_{page}.json`); returns an empty page on a CDN miss.
/// Ported from the reference's CdnRingtoneRepository.
class CdnRingtoneRepository implements RingtoneRepository {
  const CdnRingtoneRepository({required this.catalogClient});

  final CatalogHttpClient catalogClient;

  @override
  Future<CatalogPage<Ringtone>> getRingtones({int page = 1}) async {
    // Always the shared "all" catalog — category filtering is client-side over
    // the drained list (CLAUDE.md §5b: category is THE browse axis).
    final cdnPage = await catalogClient.fetchPage(
      scope: 'ringtones',
      slug: 'all',
      page: page,
      itemFromJson: Ringtone.fromJson,
    );

    if (cdnPage != null) return cdnPage;

    // CDN miss — an empty page, never a DB fallback. Page 1 missing simply
    // means no ringtone catalog has been published yet (content launches
    // later), which the screen renders as the designed "coming soon" state.
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
