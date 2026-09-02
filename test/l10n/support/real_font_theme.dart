/// Points every text style in the harness at the real faces `load_real_fonts.dart` registered.
/// Two levers, because one is not enough.
/// [applyRealFonts] rewrites the [ThemeData] -> every style descending from the theme carries a real family first.
/// That covers most of them, plus the `DefaultTextStyle` Material inserts.
/// [realizeSpan] rewrites a laid-out paragraph's span in place -> it catches what the theme cannot reach.
/// The app has sites that `copyWith(fontWeight:)` AFTER the theme resolves, and the family encodes the weight here.
/// A bumped weight would otherwise keep measuring at the theme's weight -> narrower than the truth, a false PASS.
/// The harness re-lays out after realizing spans -> overflow errors fire against corrected metrics too.
library;

import 'package:flutter/material.dart';

import 'load_real_fonts.dart';

/// Whether the harness is supplying the fonts.
/// TRUE in Layer 1 (`flutter test`) -> there is no platform and a null `fontFamily` resolves to the box face.
/// So every style has to be pointed at a registered cut BY NAME.
/// FALSE in Layer 2 on a device -> Android's own font resolution is the thing under test.
/// Naming `ArulUI600` there would ask for a family the device has never heard of.
/// Layer 2 leaves the app's real styles exactly as they ship -> that is the whole point of running it.
bool kUseHarnessFonts = true;

/// The app's own bundled faces render as themselves -> the transform only supplies their fallback chain.
/// Every other family, including one this transform already assigned, is re-derived from the weight.
/// That is what makes the transform idempotent.
const Set<String> kBundledFamilies = <String>{
  kSerifFamily,
  'Cinzel',
  'Lora',
  'Gelasio',
};

/// Gives [style] the family and fallback chain carrying its own weight's real metrics.
/// A bundled family is left alone apart from the chain -> `Marcellus` is Latin-only and must render as itself.
/// The Indic chain sits underneath it, exactly as Android hands a Tamil headline to the system fallback.
/// Same for the paywall's Cinzel, Lora and Gelasio.
TextStyle realizeTextStyle(TextStyle style) {
  if (!kUseHarnessFonts) return style;
  final weight = style.fontWeight ?? FontWeight.w400;
  final family = style.fontFamily;
  final keepFamily = family != null && kBundledFamilies.contains(family);
  return style.copyWith(
    fontFamily: keepFamily ? family : uiFamilyFor(weight),
    fontFamilyFallback: fallbackFor(weight),
  );
}

/// The same transform over a whole [TextTheme].
TextTheme realizeTextTheme(TextTheme t) => TextTheme(
  displayLarge: _r(t.displayLarge),
  displayMedium: _r(t.displayMedium),
  displaySmall: _r(t.displaySmall),
  headlineLarge: _r(t.headlineLarge),
  headlineMedium: _r(t.headlineMedium),
  headlineSmall: _r(t.headlineSmall),
  titleLarge: _r(t.titleLarge),
  titleMedium: _r(t.titleMedium),
  titleSmall: _r(t.titleSmall),
  bodyLarge: _r(t.bodyLarge),
  bodyMedium: _r(t.bodyMedium),
  bodySmall: _r(t.bodySmall),
  labelLarge: _r(t.labelLarge),
  labelMedium: _r(t.labelMedium),
  labelSmall: _r(t.labelSmall),
);

TextStyle? _r(TextStyle? s) => s == null ? null : realizeTextStyle(s);

/// The app's real [ThemeData], with every text-carrying slot pointed at the real faces.
/// Component themes are covered too -> a `SnackBar`'s content and a `Dialog`'s title live there, not on the text theme.
/// Both carry translated copy.
ThemeData applyRealFonts(ThemeData theme) {
  if (!kUseHarnessFonts) return theme;
  return theme.copyWith(
    textTheme: realizeTextTheme(theme.textTheme),
    primaryTextTheme: realizeTextTheme(theme.primaryTextTheme),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: _r(theme.snackBarTheme.contentTextStyle),
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: _r(theme.dialogTheme.titleTextStyle),
      contentTextStyle: _r(theme.dialogTheme.contentTextStyle),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: _r(theme.listTileTheme.titleTextStyle),
      subtitleTextStyle: _r(theme.listTileTheme.subtitleTextStyle),
      leadingAndTrailingTextStyle: _r(
        theme.listTileTheme.leadingAndTrailingTextStyle,
      ),
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: _r(theme.appBarTheme.titleTextStyle),
      toolbarTextStyle: _r(theme.appBarTheme.toolbarTextStyle),
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      labelStyle: _r(theme.inputDecorationTheme.labelStyle),
      floatingLabelStyle: _r(theme.inputDecorationTheme.floatingLabelStyle),
      helperStyle: _r(theme.inputDecorationTheme.helperStyle),
      hintStyle: _r(theme.inputDecorationTheme.hintStyle),
      errorStyle: _r(theme.inputDecorationTheme.errorStyle),
      counterStyle: _r(theme.inputDecorationTheme.counterStyle),
      prefixStyle: _r(theme.inputDecorationTheme.prefixStyle),
      suffixStyle: _r(theme.inputDecorationTheme.suffixStyle),
    ),
    tooltipTheme: theme.tooltipTheme.copyWith(
      textStyle: _r(theme.tooltipTheme.textStyle),
    ),
  );
}

/// Rewrites a span tree so every style in it is [realizeTextStyle]'d.
/// Returns null when nothing needed changing -> the caller can skip a re-layout it does not owe.
InlineSpan? realizeSpan(InlineSpan span) {
  if (!kUseHarnessFonts) return null;
  var changed = false;

  InlineSpan visit(InlineSpan s) {
    if (s is TextSpan) {
      final style = s.style;
      final next = style == null ? null : realizeTextStyle(style);
      if (next != style) changed = true;
      final children = s.children?.map(visit).toList();
      return TextSpan(
        text: s.text,
        children: children,
        style: next,
        recognizer: s.recognizer,
        mouseCursor: s.mouseCursor,
        onEnter: s.onEnter,
        onExit: s.onExit,
        semanticsLabel: s.semanticsLabel,
        locale: s.locale,
        spellOut: s.spellOut,
      );
    }
    return s;
  }

  final out = visit(span);
  return changed ? out : null;
}

/// True when [style] would paint box glyphs, i.e. it never got a real family.
/// The walk FAILS the suite on this rather than measuring it.
bool isUnrealizedStyle(TextStyle style) {
  if (!kUseHarnessFonts) return false;
  final f = style.fontFamily;
  return f == null || !kRegisteredFamilies.contains(f);
}
