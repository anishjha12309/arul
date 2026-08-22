/// Puts the REAL Android font stack inside the test binary.
///
/// `flutter test` renders every glyph with the FlutterTest face — a flat 1em
/// box per character, which has nothing to do with the metrics of Roboto or of
/// the five Noto Indic faces Android ships. Every width this matrix measures
/// would be fiction without this file, and fiction that fails SAFE-LOOKING:
/// English measures ~2× too wide (so a real overflow passes) while Tamil and
/// Telugu conjuncts measure at an advance they never take.
///
/// The faces come from the stock Android 16 emulator image
/// (`test/fixtures/fonts/device-android36/`, fingerprint in LICENSES.md), cut
/// into per-weight STATIC instances by `tools/l10n/instance_fonts.py`.
///
/// ## Two traps, both paid for
///
/// **1. Variable fonts load at their DEFAULT instance.** [FontLoader] does not
/// read `fontWeight:`, and `fontWeight:` drives no `wght` axis, so a raw `-VF`
/// file measures every weight at 400 — bold text would measure falsely narrow.
/// Hence the static cuts.
///
/// **2. Style matching inside a FontLoader family is INERT.** Registering the
/// per-weight cuts under one family name is the recipe that gets passed around,
/// and it silently does not work. Measured here, at 100px, on
/// `NotoSansDevanagariUI` cuts whose `usWeightClass` is demonstrably 400/500/
/// 600/700:
///
/// ```text
///   registered ascending   w400=221.10 w500=221.10 w600=221.10 w700=221.10
///   registered descending  w400=239.40 w500=239.40 w600=239.40 w700=239.40
///   the 700 cut alone      w400=239.40 …
/// ```
///
/// The FIRST-registered face wins every request; the requested weight is never
/// consulted. (Noto Tamil happened to resolve correctly under the same
/// treatment, and Roboto served its 700 cut for a w600 request — the behaviour
/// is per-font, which is worse than uniformly broken because it looks fine
/// until you check the one font that isn't.)
///
/// So: **one family per (script, weight), single face each**, and the harness
/// picks the family from the weight itself — see [uiFamilyFor] / [fallbackFor].
/// Nothing is left to the matcher.
///
/// The app asks for `fontFamily: null` almost everywhere (the platform stack —
/// `lib/app/theme/typography.dart`). A null family in the test binary resolves
/// to the box face and NOT to anything registered here, so naming the stack is
/// the harness's job: `real_font_theme.dart`.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled display serif, under its shipping name so the theme's
/// `fontFamily: 'Marcellus'` slots resolve to the real face. Marcellus is
/// Latin-only; an Indic headline falls through [fallbackFor] exactly as it
/// falls through Android's system chain on device.
const String kSerifFamily = 'Marcellus';

/// Latin cuts the fixtures provide. Roboto's `wght` axis spans 100–900, so
/// every weight the theme asks for exists.
const List<int> kLatinWeights = <int>[400, 500, 600, 700, 800];

/// Indic cuts the fixtures provide. The Noto `wght` axes stop at 700 — which is
/// also where a real phone stops, so a `w800` Indic slot resolving to the 700
/// cut is fidelity, not an approximation.
const List<int> kIndicWeights = <int>[400, 500, 600, 700];

/// Script tag → the family-name prefix its per-weight families use.
const Map<String, String> kIndicPrefixes = <String, String>{
  'ta': 'ArulTa',
  'te': 'ArulTe',
  'kn': 'ArulKn',
  'ml': 'ArulMl',
  'hi': 'ArulHi',
};

const String _latinPrefix = 'ArulUI';

const Map<String, String> _indicStems = <String, String>{
  'ta': 'NotoSansTamilUI-VF',
  'te': 'NotoSansTeluguUI-VF',
  'kn': 'NotoSansKannadaUI-VF',
  'ml': 'NotoSansMalayalamUI-VF',
  'hi': 'NotoSansDevanagariUI-VF',
};

const String _latinStem = 'Roboto-Regular';

final _fixtures = Directory('test/fixtures/fonts/device-android36');
final _instanced = Directory('test/fixtures/fonts/device-android36/instanced');
final _assetFonts = Directory('assets/fonts');

bool _loaded = false;

/// Every family this harness registers. Anything a rendered paragraph resolves
/// to that is NOT in here would paint box glyphs, so the walk treats it as a
/// harness failure rather than as a measurement.
final Set<String> kRegisteredFamilies = <String>{
  for (final w in kLatinWeights) '$_latinPrefix$w',
  for (final p in kIndicPrefixes.values)
    for (final w in kIndicWeights) '$p$w',
  kSerifFamily,
  'Cinzel',
  'Lora',
  'Gelasio',
};

int _nearest(List<int> available, int want) {
  var best = available.first;
  for (final w in available) {
    if ((w - want).abs() < (best - want).abs()) best = w;
  }
  return best;
}

/// The Latin family that carries [weight]'s real metrics.
String uiFamilyFor(FontWeight weight) =>
    '$_latinPrefix${_nearest(kLatinWeights, weight.value)}';

/// The fallback chain for [weight]: Latin first (it owns digits, punctuation,
/// ₹ and any Latin word inside a translated string), then one family per Indic
/// script at the same weight. Scripts share no codepoints, so their order among
/// themselves is immaterial.
List<String> fallbackFor(FontWeight weight) {
  final indic = _nearest(kIndicWeights, weight.value);
  return <String>[
    uiFamilyFor(weight),
    for (final p in kIndicPrefixes.values) '$p$indic',
  ];
}

/// Registers the real faces. Idempotent, so every file in the matrix can call
/// it from `setUpAll` without paying for it twice.
///
/// Throws — loudly, before a single measurement is taken — if a fixture or an
/// instanced cut is missing. A silently short font list is the one failure mode
/// that yields a GREEN matrix built from fictional metrics.
Future<void> loadRealFonts() async {
  if (_loaded) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_fixtures.existsSync()) {
    throw StateError(
      'Font fixtures missing: ${_fixtures.path}\n'
      'Re-pull from the emulator (OVERNIGHT-L10N.md Appendix A step 6).',
    );
  }
  if (!_instanced.existsSync()) {
    throw StateError(
      'Static instances missing: ${_instanced.path}\n'
      'Run: python tools/l10n/instance_fonts.py',
    );
  }

  for (final w in kLatinWeights) {
    await _register('$_latinPrefix$w', [_cut('$_latinStem-w$w.ttf')]);
  }
  for (final script in kIndicPrefixes.keys) {
    final stem = _indicStems[script]!;
    for (final w in kIndicWeights) {
      await _register('${kIndicPrefixes[script]}$w', [_cut('$stem-w$w.ttf')]);
    }
  }

  final marcellus = File('${_assetFonts.path}/Marcellus-Regular.ttf');
  if (!marcellus.existsSync()) {
    throw StateError('Missing bundled serif: ${marcellus.path}');
  }
  await _register(kSerifFamily, [marcellus]);

  // The remaining bundled faces under their shipping names. The paywall tree is
  // English-by-decision and out of the matrix, but the app builds these styles
  // while constructing the theme, and a missing family there would surface as
  // noise in the findings rather than as signal.
  for (final entry in const {
    'Cinzel': ['Cinzel-Medium.ttf'],
    'Lora': [
      'Lora-Regular.ttf',
      'Lora-Medium.ttf',
      'Lora-SemiBold.ttf',
      'Lora-Italic.ttf',
    ],
    'Gelasio': ['Gelasio-Regular.ttf'],
  }.entries) {
    final files = entry.value
        .map((n) => File('${_assetFonts.path}/$n'))
        .where((f) => f.existsSync())
        .toList();
    if (files.isNotEmpty) await _register(entry.key, files);
  }

  _loaded = true;
}

File _cut(String name) {
  final f = File('${_instanced.path}/$name');
  if (!f.existsSync()) {
    throw StateError(
      'Missing instanced cut ${f.path}\n'
      'Run: python tools/l10n/instance_fonts.py',
    );
  }
  return f;
}

Future<void> _register(String family, List<File> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      f.readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
    );
  }
  await loader.load();
}
