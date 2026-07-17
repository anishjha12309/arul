import '../../../data/models/catalog_page.dart';
import '../../../data/models/ringtone.dart';

/// Read side of the ringtone catalog (CDN-only — never the DB, CLAUDE.md §2).
abstract interface class RingtoneRepository {
  Future<CatalogPage<Ringtone>> getRingtones({int page = 1});
}
