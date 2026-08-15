/// Which artwork a ringtone row wears.
///
/// One transparent gold figure per deity, bundled under `assets/ringtones/` and
/// composited over the hashed jewel-tone ground [RingtoneTile] still draws. The
/// art replaced six hand-drawn `CustomPainter` motifs that were keyed off
/// `category`, which could only ever be as specific as the browse axis — and
/// the browse axis is deliberately coarse (CLAUDE.md §5b). `perumal` alone
/// spans Venkateswara, Krishna, Rama and Narasimha; `amman` spans six
/// goddesses. Category-level art put one emblem on all of them.
///
/// ── THE RESOLUTION CHAIN ───────────────────────────────────────────────────
/// deity's own asset → the CATEGORY's default asset → `fallback.png`.
///
/// The middle link is the load-bearing one. `deity` is nullable and free text:
/// rows authored before the column existed carry null, the CMS can save one
/// without it, and a bulk import can invent a slug this app release has never
/// heard of. Without the category step every one of those lands on a neutral
/// gopuram — technically fine, visibly wrong for a Murugan track sitting in a
/// list of Murugan tracks. With it, the worst case for a known category is the
/// right *family* of god, and only a genuinely new category reaches the
/// fallback. That is what keeps a new deity an insert plus an app release for
/// its PNG, never a migration.
library;

const String _base = 'assets/ringtones';

/// The neutral tile: a three-tier gopuram. Not a deity — what an unrecognised
/// category gets, and the only art that may stand for nothing in particular.
const String kFallbackDeityAsset = '$_base/fallback.png';

/// Every deity slug that ships a PNG in this release.
///
/// A slug missing from here is not a bug — it is a catalog that moved ahead of
/// the app, which the chain above is built to survive. Adding one means adding
/// the asset AND the entry; a test asserts the two stay in step, because an
/// entry without its file throws at paint time on a device and never in CI.
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
/// `vishnu` and `devi` are the generic members of their families ON PURPOSE —
/// four-armed Narayana and an unattributed mother goddess — precisely so they
/// can stand for a track whose form nobody has identified. Never point these at
/// a specific form: `venkateswara` here would mislabel every Krishna and Rama
/// track that arrives without a deity.
///
/// `others` is absent by design. It is the catch-all whose members are
/// deliberately unlike each other (Ganesha, Hanuman), so there is no honest
/// default — those rows go to the fallback rather than wear another god's face.
/// `temples` is likewise absent: no ringtone uses it, and a stray row is better
/// served by the gopuram than by a deity picked at random.
const Map<String, String> _defaultDeityByCategory = {
  'murugan': 'murugan',
  'ayyappan': 'ayyappan',
  'sivan': 'sivan',
  'perumal': 'vishnu',
  'amman': 'devi',
};

/// The bundled asset path for one row. Never returns null and never returns a
/// path with no file behind it.
///
/// Both inputs are free text off the catalog, so both are lowercased and
/// trimmed before they are looked up — a `Murugan` or `perumal ` out of the CMS
/// must not silently fall through to the gopuram.
String deityAsset({String? deity, String? category}) {
  final d = deity?.trim().toLowerCase();
  if (d != null && kDeityArtSlugs.contains(d)) return '$_base/$d.png';

  final c = category?.trim().toLowerCase();
  final fallbackSlug = c == null ? null : _defaultDeityByCategory[c];
  if (fallbackSlug != null) return '$_base/$fallbackSlug.png';

  return kFallbackDeityAsset;
}

/// Every asset path this release can ask for — the test's checklist, and the
/// list to precache against if the tab ever needs it.
Iterable<String> get allDeityAssets sync* {
  for (final slug in kDeityArtSlugs) {
    yield '$_base/$slug.png';
  }
  yield kFallbackDeityAsset;
}
