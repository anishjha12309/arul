/// Rendered string -> ARB key.
/// A finding is only actionable if it names a key -> the fix removes that key from all five non-English ARBs.
/// So an unattributed overflow is a finding nobody can act on.
/// Matching is exact first, then template-regex for the parameterized messages.
/// Then the shapes the widget tree imposes -> a `Text.rich` splits one message across spans, a `\n` message arrives whole.
/// Anything still unmatched is reported as unattributed rather than guessed at.
library;

import 'arb_index.g.dart';

/// Stamped into a finding's detail when the rendered string maps to MORE THAN ONE ARB key.
/// Nothing downstream may then treat the guess as certain.
/// English strings collide -> 'Upload your content' is both uploadTitle and settingsUpload.
/// While the translations differ the collision exists only in English and fails safe.
/// But demote one of a colliding pair and all six locales render the same English string.
/// Every locale then attributes to whichever key sorts first -> a real finding could be subtracted against the OTHER key.
/// So an ambiguous finding is NEVER baseline-subtracted.
const String kAmbiguousMarker = '[ambiguous-attribution]';

class Attributor {
  Attributor(this.locale)
    : _exact = _buildExact(locale),
      _templates = _buildTemplates(locale);

  final String locale;
  final Map<String, List<String>> _exact;
  final List<_Template> _templates;

  static final Map<String, Attributor> _cache = {};

  factory Attributor.of(String locale) =>
      _cache.putIfAbsent(locale, () => Attributor(locale));

  /// Every string this locale can render, for the "did we exercise it?" ledger.
  static Map<String, String> stringsFor(String locale) => {
    // A demoted key is absent from a non-English ARB and gen_l10n back-fills the English template.
    // So the English map is the fallback -> exactly what the user sees.
    ...kArbStrings['en']!,
    ...?kArbStrings[locale],
  };

  static Map<String, List<String>> _buildExact(String locale) {
    final out = <String, List<String>>{};
    stringsFor(locale).forEach((key, value) {
      if (kArbPlaceholders.containsKey(key)) return;
      (out[value] ??= []).add(key);
    });
    return out;
  }

  static List<_Template> _buildTemplates(String locale) {
    final strings = stringsFor(locale);
    final out = <_Template>[];
    for (final key in kArbPlaceholders.keys) {
      final template = strings[key];
      if (template == null) continue;
      out.add(_Template(key, template));
    }
    // Longest template FIRST -> a long message must not be shadowed by a shorter pattern that also matches.
    out.sort((a, b) => b.template.length.compareTo(a.template.length));
    return out;
  }

  /// The key [rendered] came from, or null.
  String? attribute(String rendered) {
    final text = rendered.trim();
    if (text.isEmpty) return null;

    final exact = _exact[text];
    if (exact != null) return exact.first;

    for (final t in _templates) {
      if (t.matches(text)) return t.key;
    }

    // A multi-line message reaches one paragraph whole but a Column of Texts one line at a time.
    // So match a line against the message it belongs to.
    for (final entry in _exact.entries) {
      if (!entry.key.contains('\n')) continue;
      for (final line in entry.key.split('\n')) {
        if (line.trim() == text) return entry.value.first;
      }
    }
    return null;
  }

  /// True when [rendered] maps to more than one ARB key -> any attribution of it is a guess (see [kAmbiguousMarker]).
  bool isAmbiguous(String rendered) =>
      (_exact[rendered.trim()] ?? const []).length > 1;

  /// True when [rendered] is one of this locale's authored strings at all.
  /// It separates "a translated string overflowed" from "a fake wallpaper title overflowed", which is out of scope.
  /// Only UI chrome is localized (CLAUDE.md §6).
  bool isAuthored(String rendered) => attribute(rendered) != null;
}

class _Template {
  _Template(this.key, this.template) : _pattern = _compile(template);

  final String key;
  final String template;
  final RegExp _pattern;

  bool matches(String text) => _pattern.hasMatch(text);

  /// Turns a templated message into a regex that accepts any substitution.
  /// The literal parts are escaped -> a `.` in the copy cannot match an arbitrary character and widen the net.
  static RegExp _compile(String template) {
    final buf = StringBuffer('^');
    var index = 0;
    final placeholder = RegExp(r'\{(\w+)\}');
    for (final m in placeholder.allMatches(template)) {
      buf.write(RegExp.escape(template.substring(index, m.start)));
      buf.write(r'.+?');
      index = m.end;
    }
    buf
      ..write(RegExp.escape(template.substring(index)))
      ..write(r'$');
    return RegExp(buf.toString(), dotAll: true);
  }
}
