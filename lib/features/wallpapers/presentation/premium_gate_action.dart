/// The two premium-gated verbs on a wallpaper.
enum PremiumGateAction {
  apply('apply'),
  share('share');

  const PremiumGateAction(this.source);

  final String source;
}
