import 'package:flutter/material.dart';

import 'arul_tokens.dart';

/// The colour ROLES of the current theme, resolved once: a widget asks `ArulPalette.of(context)`
/// for `text` or `accent` instead of re-deciding the brightness at every site.
/// Every value is an existing [ArulTokens] colour: this adds names, never new paint.
@immutable
class ArulPalette extends ThemeExtension<ArulPalette> {
  const ArulPalette({
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.accentTint,
    required this.goldInk,
    required this.chromeInk,
    required this.controlInk,
    required this.controlFill,
    required this.surface,
    required this.sheet,
    required this.sheetGradient,
    required this.card,
    required this.field,
    required this.tile,
    required this.border,
    required this.borderQuiet,
    required this.divider,
    required this.rim,
    required this.controlRim,
    required this.outline,
    required this.grabber,
    required this.dash,
    required this.danger,
    required this.destructiveInk,
    required this.destructiveRim,
    required this.destructiveFill,
    required this.destructiveChip,
    required this.silk,
    required this.silkRim,
    required this.dockFill,
    required this.dockRim,
    required this.dockShadow,
    required this.dockActiveFill,
    required this.dockActiveRim,
    required this.overlayShadow,
    required this.litEdge,
    required this.medallionFill,
    required this.medallionRing,
  });

  static const dark = ArulPalette(
    text: ArulTokens.darkText,
    textSecondary: ArulTokens.darkTextSecondary,
    textMuted: ArulTokens.darkMuted,
    textFaint: ArulTokens.darkFaint,
    accent: ArulTokens.gold,
    onAccent: ArulTokens.darkSurface,
    accentTint: ArulTokens.goldTintFill12,
    goldInk: ArulTokens.gold,
    chromeInk: ArulTokens.gold,
    controlInk: ArulTokens.ivoryText86,
    // A rim alone on dark: the row's ground shows through the idle control.
    controlFill: Color(0x00000000),
    surface: ArulTokens.darkSurface,
    sheet: ArulTokens.darkSheetSurface,
    sheetGradient: ArulTokens.sheetGradientDark,
    card: ArulTokens.cardBgDark04,
    field: ArulTokens.cardBgDark05,
    tile: ArulTokens.cardBgDark05,
    border: ArulTokens.cardBorderDark14,
    borderQuiet: ArulTokens.cardBorderDark09,
    divider: ArulTokens.rowDividerDark,
    rim: ArulTokens.goldBorder35,
    controlRim: ArulTokens.ivoryBorder22,
    outline: ArulTokens.grabberColorDark,
    grabber: ArulTokens.grabberColorDark,
    dash: ArulTokens.goldBorder50,
    danger: ArulTokens.dangerInkDark,
    destructiveInk: ArulTokens.destructiveInkDark,
    destructiveRim: ArulTokens.maroonBorder55,
    destructiveFill: ArulTokens.maroonTintFill35,
    destructiveChip: ArulTokens.maroonTintFill35,
    silk: ArulTokens.silkDark,
    silkRim: ArulTokens.silkBorderDark,
    dockFill: ArulTokens.dockFillDark,
    dockRim: ArulTokens.cardBorderDark08,
    dockShadow: ArulTokens.dockShadowDark,
    dockActiveFill: ArulTokens.goldTintFill13,
    dockActiveRim: ArulTokens.goldBorder45,
    // A shadow is invisible on the dark ground; a raised surface there lifts by its fill and rim.
    overlayShadow: <BoxShadow>[],
    litEdge: ArulTokens.litEdgeDark,
    medallionFill: ArulTokens.goldTintFill12,
    medallionRing: ArulTokens.goldBorder50,
  );

  static const light = ArulPalette(
    text: ArulTokens.lightText,
    textSecondary: ArulTokens.lightSecondary,
    textMuted: ArulTokens.lightSecondary,
    textFaint: ArulTokens.lightFaint,
    accent: ArulTokens.maroon,
    onAccent: ArulTokens.ivory,
    accentTint: ArulTokens.maroonTintFill07,
    goldInk: ArulTokens.goldInkLight,
    chromeInk: ArulTokens.lightText,
    controlInk: ArulTokens.maroon,
    controlFill: ArulTokens.cardBgLight,
    surface: ArulTokens.ivory,
    sheet: ArulTokens.cardBgLight,
    sheetGradient: null,
    card: ArulTokens.cardBgLight,
    field: ArulTokens.cardBgLight,
    tile: ArulTokens.maroonTintFill07,
    border: ArulTokens.cardBorderLight,
    borderQuiet: ArulTokens.cardBorderLight,
    divider: ArulTokens.dividerLight,
    rim: ArulTokens.maroonBorder18,
    controlRim: ArulTokens.maroonBorder18,
    outline: ArulTokens.maroonBorder18,
    grabber: ArulTokens.grabberColorLight,
    dash: ArulTokens.maroonBorder45,
    danger: ArulTokens.maroon,
    destructiveInk: ArulTokens.maroon,
    destructiveRim: ArulTokens.maroonBorder35,
    destructiveFill: ArulTokens.maroonTintFill08,
    destructiveChip: ArulTokens.maroonTintFill14,
    silk: ArulTokens.silkLight,
    silkRim: ArulTokens.silkBorderLight,
    dockFill: ArulTokens.cardBgLight,
    dockRim: ArulTokens.maroonBorder08,
    dockShadow: ArulTokens.dockShadowLight,
    dockActiveFill: ArulTokens.dockActiveFillLight,
    dockActiveRim: ArulTokens.goldBorder50,
    overlayShadow: ArulTokens.overlayShadowLight,
    litEdge: null,
    medallionFill: ArulTokens.paywallMedallionFill,
    medallionRing: ArulTokens.paywallGold600,
  );

  /// The theme's palette. A bare `MaterialApp` (a test, a sheet pinned to one brightness) has no
  /// extension, so it falls back on the brightness.
  static ArulPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ArulPalette>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  /// Primary type and glyphs on [surface], [sheet] and [card].
  final Color text;
  final Color textSecondary;

  /// Quiet labels a step below [textSecondary]: an idle dock cell, a state view's body.
  final Color textMuted;

  /// Hints, counters, footnotes, chevrons: the faintest ink that still clears WCAG AA.
  final Color textFaint;

  /// Selection, focus and brand glyphs: gold on dark, maroon on light.
  final Color accent;

  /// Type and glyphs ON an [accent] fill.
  final Color onAccent;

  /// The quiet accent wash behind an icon badge or a track.
  final Color accentTint;

  /// Gold TYPE: raw gold on dark; on light the darkened gold that clears AA on ivory.
  final Color goldInk;

  /// Brand chrome ink: header titles and the active dock cell (gold on dark, plain ink on light).
  final Color chromeInk;

  /// A round media control's glyph (play, pause) on its own rim, and the disc behind it at rest.
  final Color controlInk;
  final Color controlFill;

  final Color surface;

  /// The ground of anything raised over the page: sheets, dialogs, cards that float.
  final Color sheet;

  /// Dark sheets light from the top; light ones are flat [sheet].
  final Gradient? sheetGradient;

  final Color card;

  /// A form field's ground.
  final Color field;

  /// An option tile inside a sheet (apply targets, share cells).
  final Color tile;

  /// Card and field rims at rest.
  final Color border;

  /// The rim of a list that sits on the page rather than over it.
  final Color borderQuiet;

  final Color divider;

  /// The edge of a raised surface: gold on dark, maroon-tinted on light.
  final Color rim;

  /// A round media control's rim.
  final Color controlRim;

  /// A secondary (outline) button's rim.
  final Color outline;

  final Color grabber;

  /// The dashed rim of a pick zone.
  final Color dash;

  /// Error text and glyphs.
  final Color danger;

  /// The irreversible acts (delete account, logout): ink, rim, button fill and icon chip.
  final Color destructiveInk;
  final Color destructiveRim;
  final Color destructiveFill;
  final Color destructiveChip;

  /// The profile card's silk ground and its rim.
  final Gradient silk;
  final Color silkRim;

  final Color dockFill;
  final Color dockRim;
  final List<BoxShadow> dockShadow;
  final Color dockActiveFill;
  final Color dockActiveRim;

  /// The lift under a floating surface: a warm shadow on light, none on dark.
  final List<BoxShadow> overlayShadow;

  /// The lamp-lit top edge of a raised surface: gold on dark; light surfaces lift by shadow instead.
  final Gradient? litEdge;

  /// A premium medallion's ground and ring — the paywall's own on light.
  final Color medallionFill;
  final Color medallionRing;

  @override
  ArulPalette copyWith({
    Color? text,
    Color? textSecondary,
    Color? textMuted,
    Color? textFaint,
    Color? accent,
    Color? onAccent,
    Color? accentTint,
    Color? goldInk,
    Color? chromeInk,
    Color? controlInk,
    Color? controlFill,
    Color? surface,
    Color? sheet,
    Gradient? sheetGradient,
    Color? card,
    Color? field,
    Color? tile,
    Color? border,
    Color? borderQuiet,
    Color? divider,
    Color? rim,
    Color? controlRim,
    Color? outline,
    Color? grabber,
    Color? dash,
    Color? danger,
    Color? destructiveInk,
    Color? destructiveRim,
    Color? destructiveFill,
    Color? destructiveChip,
    Gradient? silk,
    Color? silkRim,
    Color? dockFill,
    Color? dockRim,
    List<BoxShadow>? dockShadow,
    Color? dockActiveFill,
    Color? dockActiveRim,
    List<BoxShadow>? overlayShadow,
    Gradient? litEdge,
    Color? medallionFill,
    Color? medallionRing,
  }) => ArulPalette(
    text: text ?? this.text,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    textFaint: textFaint ?? this.textFaint,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    accentTint: accentTint ?? this.accentTint,
    goldInk: goldInk ?? this.goldInk,
    chromeInk: chromeInk ?? this.chromeInk,
    controlInk: controlInk ?? this.controlInk,
    controlFill: controlFill ?? this.controlFill,
    surface: surface ?? this.surface,
    sheet: sheet ?? this.sheet,
    sheetGradient: sheetGradient ?? this.sheetGradient,
    card: card ?? this.card,
    field: field ?? this.field,
    tile: tile ?? this.tile,
    border: border ?? this.border,
    borderQuiet: borderQuiet ?? this.borderQuiet,
    divider: divider ?? this.divider,
    rim: rim ?? this.rim,
    controlRim: controlRim ?? this.controlRim,
    outline: outline ?? this.outline,
    grabber: grabber ?? this.grabber,
    dash: dash ?? this.dash,
    danger: danger ?? this.danger,
    destructiveInk: destructiveInk ?? this.destructiveInk,
    destructiveRim: destructiveRim ?? this.destructiveRim,
    destructiveFill: destructiveFill ?? this.destructiveFill,
    destructiveChip: destructiveChip ?? this.destructiveChip,
    silk: silk ?? this.silk,
    silkRim: silkRim ?? this.silkRim,
    dockFill: dockFill ?? this.dockFill,
    dockRim: dockRim ?? this.dockRim,
    dockShadow: dockShadow ?? this.dockShadow,
    dockActiveFill: dockActiveFill ?? this.dockActiveFill,
    dockActiveRim: dockActiveRim ?? this.dockActiveRim,
    overlayShadow: overlayShadow ?? this.overlayShadow,
    litEdge: litEdge ?? this.litEdge,
    medallionFill: medallionFill ?? this.medallionFill,
    medallionRing: medallionRing ?? this.medallionRing,
  );

  @override
  ArulPalette lerp(ArulPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? b;
    return ArulPalette(
      text: mix(text, other.text),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      textFaint: mix(textFaint, other.textFaint),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      accentTint: mix(accentTint, other.accentTint),
      goldInk: mix(goldInk, other.goldInk),
      chromeInk: mix(chromeInk, other.chromeInk),
      controlInk: mix(controlInk, other.controlInk),
      controlFill: mix(controlFill, other.controlFill),
      surface: mix(surface, other.surface),
      sheet: mix(sheet, other.sheet),
      sheetGradient: Gradient.lerp(sheetGradient, other.sheetGradient, t),
      card: mix(card, other.card),
      field: mix(field, other.field),
      tile: mix(tile, other.tile),
      border: mix(border, other.border),
      borderQuiet: mix(borderQuiet, other.borderQuiet),
      divider: mix(divider, other.divider),
      rim: mix(rim, other.rim),
      controlRim: mix(controlRim, other.controlRim),
      outline: mix(outline, other.outline),
      grabber: mix(grabber, other.grabber),
      dash: mix(dash, other.dash),
      danger: mix(danger, other.danger),
      destructiveInk: mix(destructiveInk, other.destructiveInk),
      destructiveRim: mix(destructiveRim, other.destructiveRim),
      destructiveFill: mix(destructiveFill, other.destructiveFill),
      destructiveChip: mix(destructiveChip, other.destructiveChip),
      silk: Gradient.lerp(silk, other.silk, t) ?? other.silk,
      silkRim: mix(silkRim, other.silkRim),
      dockFill: mix(dockFill, other.dockFill),
      dockRim: mix(dockRim, other.dockRim),
      dockShadow:
          BoxShadow.lerpList(dockShadow, other.dockShadow, t) ??
          other.dockShadow,
      dockActiveFill: mix(dockActiveFill, other.dockActiveFill),
      dockActiveRim: mix(dockActiveRim, other.dockActiveRim),
      overlayShadow:
          BoxShadow.lerpList(overlayShadow, other.overlayShadow, t) ??
          other.overlayShadow,
      litEdge: Gradient.lerp(litEdge, other.litEdge, t),
      medallionFill: mix(medallionFill, other.medallionFill),
      medallionRing: mix(medallionRing, other.medallionRing),
    );
  }
}
