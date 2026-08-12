/// The two premium-gated verbs on a wallpaper. Browse and preview are free;
/// Apply and Share are gated (CLAUDE.md §5).
///
/// It carries nothing but the analytics/route token, because a blocked tap now
/// goes straight to `/premium` — there is no interstitial left to hold copy. It
/// used to own the nudge pill's two half-sentences ("Applying is a premium treat
/// — try it free"), which is also why they were never localized: the pill and the
/// teaser sheet were both dropped on 2026-08-11 in favour of the paywall itself.
enum PremiumGateAction {
  apply('apply'),
  share('share');

  const PremiumGateAction(this.source);

  /// The `?source=` value forwarded to `/premium` and the stem of the
  /// `${source}_blocked_premium` analytics event.
  final String source;
}
