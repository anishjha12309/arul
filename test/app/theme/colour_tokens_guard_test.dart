// Colours come from tokens and roles from the palette: a raw colour or a brightness-picked pair in a
// screen is how two "same" greys drift apart. The theme files and drawn ARTWORK are the exceptions
// (docs/ui-direction.md §Drawn art is ARTWORK).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where colours are DEFINED.
const _themeDirs = ['lib/theme/', 'lib/app/theme/', 'lib/app/l10n/'];

/// Pictures, not chrome: their grounds and inks are part of the drawing and must not become tokens.
const _artwork = <String>{
  'lib/features/ringtones/presentation/ringtone_tile.dart',
  'lib/app/widgets/kolam_painter.dart',
  // Pixels baked into an exported image, not app chrome.
  'lib/features/wallpapers/data/share_watermark_service.dart',
};

/// A literal colour: `Color(0x…)` (bar the transparent system-bar sentinel), `Color.fromRGBO/ARGB`,
/// or a named Material colour other than `Colors.transparent`.
final _rawColour = RegExp(
  r'Color\(0x(?!00000000\))|Color\.from(?:RGBO|ARGB)\(|\bColors\.(?!transparent\b)[a-z]\w*',
);

/// A colour chosen by brightness at the call site instead of read from `ArulPalette`.
final _pickedPair = RegExp(
  r'\b(?:isDark|dark)\s*\?\s*(?:const\s+)?(?:ArulTokens|ArulColors|Colors|Color)\b',
);

Iterable<File> _sources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
    .where((f) => !_themeDirs.any((d) => f.path.startsWith(d)));

List<String> _hits(RegExp pattern, {Set<String> except = const {}}) {
  final out = <String>[];
  for (final f in _sources()) {
    if (except.contains(f.path)) continue;
    final text = f.readAsStringSync();
    for (final m in pattern.allMatches(text)) {
      final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
      out.add('${f.path}:$line  ${m.group(0)}');
    }
  }
  return out;
}

void main() {
  test('no raw colour outside the theme files and artwork', () {
    expect(_hits(_rawColour, except: _artwork), isEmpty);
  });

  test('no brightness-picked colour outside the theme files', () {
    expect(_hits(_pickedPair, except: _artwork), isEmpty);
  });
}
