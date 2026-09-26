library;

const String _base = 'assets/ringtones';

const String kFallbackDeityAsset = '$_base/fallback.webp';

/// Every deity slug that ships a WebP in this release.
///
/// A missing slug is not a bug -> it is a catalog that moved ahead of the app, which the chain above
/// is built to survive.
/// An entry without its file throws at paint time on a device and never in CI -> add the asset AND
/// the entry -> a test asserts the two stay in step.
const Set<String> kDeityArtSlugs = {
  'murugan',
  'ayyappan',
  'sivan',
  'venkateswara',
  'krishna',
  'rama',
  'narasimha',
  'vishnu',
  'lakshmi',
  'mariamman',
  'durga',
  'meenakshi',
  'parvati',
  'devi',
  'ganesha',
  'hanuman',
};

/// A category's stand-in when the row's own deity resolves to nothing.
///
/// `vishnu` and `devi` are the GENERIC members of their families on purpose — four-armed Narayana,
/// an unattributed mother goddess -> they can stand for a track whose form nobody identified.
/// Never point one of these at a specific form -> `venkateswara` here would mislabel every Krishna
/// and Rama track that arrives without a deity.
/// `others` is absent by design: its members are deliberately unlike each other (Ganesha, Hanuman)
/// -> no honest default -> those rows take the fallback rather than wear another god's face.
/// `temples` is absent too -> no ringtone uses it, and a stray row is better served by the gopuram
/// than by a deity picked at random.
const Map<String, String> _defaultDeityByCategory = {
  'murugan': 'murugan',
  'ayyappan': 'ayyappan',
  'sivan': 'sivan',
  'perumal': 'vishnu',
  'amman': 'devi',
};

/// The bundled asset path for one row -> never null, and never a path with no file behind it.
///
/// Both inputs are free text off the catalog -> a `Murugan` or `perumal ` out of the CMS would fall
/// silently through to the gopuram -> lowercase and trim both before the lookup.
String deityAsset({String? deity, String? category}) {
  final d = deity?.trim().toLowerCase();
  if (d != null && kDeityArtSlugs.contains(d)) return '$_base/$d.webp';

  final c = category?.trim().toLowerCase();
  final fallbackSlug = c == null ? null : _defaultDeityByCategory[c];
  if (fallbackSlug != null) return '$_base/$fallbackSlug.webp';

  return kFallbackDeityAsset;
}

Iterable<String> get allDeityAssets sync* {
  for (final slug in kDeityArtSlugs) {
    yield '$_base/$slug.webp';
  }
  yield kFallbackDeityAsset;
}
