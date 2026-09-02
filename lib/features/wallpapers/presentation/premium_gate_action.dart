/// The two premium-gated verbs on a wallpaper.
///
/// Browse and preview are free; apply and share are gated (CLAUDE.md §5).
/// A blocked tap goes STRAIGHT to `/premium` -> no nudge pill, no teaser sheet, no interstitial ->
/// nothing here holds copy but the analytics/route token.
enum PremiumGateAction {
  apply('apply'),
  share('share');

  const PremiumGateAction(this.source);

  /// The `?source=` value forwarded to `/premium` and the stem of the
  /// `${source}_blocked_premium` analytics event.
  final String source;
}
