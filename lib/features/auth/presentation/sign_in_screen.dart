import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/l10n/app_localizations.dart';
import '../../../app/widgets/arul_toast.dart';
import '../../../core/config/app_config.dart';
import '../../../core/haptics/arul_haptics.dart';
import '../../../core/perf/boot_trace.dart';
import '../../../core/providers/locale_provider.dart';
import '../../../theme/arul_tokens.dart';
import '../../legal/presentation/policy_screen.dart';
import '../../settings/presentation/language_sheet.dart';
import '../domain/auth_service.dart';
import '../domain/sign_in_outcome.dart';
import '../providers/auth_providers.dart';
import 'widgets/video_background.dart';

/// Sign-in.
///
/// This IS a wall, deliberately (owner's call) — every signed-out session lands here, no skip.
/// Browse and preview being free (§5) is about the MEDIA gate, not about reaching the feed unauthed.
/// **PHASE CONTRACT:** the screen AUTO-LAUNCHES a Google credential request on its FIRST FRAME.
/// That request is SHEET-FIRST — Credential Manager bottom sheet, then the button flow (SIWG guide).
/// The wall only works because a surface appears without a tap -> never a silent, no-UI check.
/// ONE visible Google surface per attempt -> the picker follows only when the sheet drew NOTHING.
/// A sheet run as a WARM-UP ahead of a picker stays forbidden — it appeared, hung and vanished.
/// The pill is the button flow — Google's fallback for a dismissed sheet, no accounts, or re-auth.
/// A tap therefore SKIPS the sheet.
/// Generic "Continue with Google" copy, never a named identity — the account choice is Google's.
/// The background player is SHARED with the splash -> arriving here never re-inits a MediaCodec.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.debugOutcome});

  /// Renders the screen as if an attempt had just ended this way, without running one.
  /// The l10n and size matrices pump every outcome through here; nothing else may set it.
  @visibleForTesting
  final SignInOutcome? debugOutcome;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  /// The splash's eyebrow, repeated so the two brand beats read as one handoff.
  /// Same string, same [ArulTokens.tagline] — change one and you must change the other.
  /// Latin-only and UNLOCALIZED with the wordmark: both are the brand mark, not copy.
  static const _tagline = 'DEVOTIONAL WALLPAPERS & RINGTONES';

  bool _signingIn = false;

  /// What the last ended-without-a-session attempt actually did, or null while nothing has failed.
  ///
  /// A cancel stays TOAST-less — half of "cancels" are GMS-side aborts the user never chose.
  /// A silent bounce to an unchanged screen read as "nothing happened" -> the subtitle is the middle.
  /// One line for every cancel was the OTHER failure: "didn't go through, tap again" told a user
  /// whose Play services closed the window nothing they could act on. The line must be true of THIS
  /// attempt, so it is routed off [SignInOutcome] and never off a bool.
  /// NEVER auto-relaunch on a cancel — the Credential Manager guide forbids retrying the request.
  SignInOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    _outcome = widget.debugOutcome;
    _initAutoLaunch();
  }

  void _initAutoLaunch() {
    BootTrace.mark('signIn screen: initState');
    // CONTRACT: auto-launch the credential request on the FIRST FRAME (initialize → sheet → button).
    // The pill below is the button flow on its own.
    // The guard is defensive — both defines are always set in shipped builds.
    // A define-less run has nothing to authenticate against -> skip it, the pill passes through.
    if (AppConfig.hasBackend && AppConfig.googleAuthConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        BootTrace.mark('signIn screen: first frame → auto-launch');
        _signIn(auto: true);
      });
    }
  }

  /// [auto] is the first-frame launch — it JOINS whatever the splash started, never a second picker.
  /// It does nothing at all once that one attempt has been spent and dismissed.
  /// [auto] false is the pill, which may always start a fresh attempt.
  Future<void> _signIn({bool auto = false}) async {
    if (_signingIn) return;
    final notifier = ref.read(authControllerProvider.notifier);
    final pending = auto
        ? notifier.autoSignIn(AuthProvider.google)
        : notifier.signIn(AuthProvider.google);
    // Auto-launch already spent.
    // A fast failure can settle on the splash with nothing awaiting it -> surface it NOW.
    // The contract is a message plus retry, never a silent bounce; a cancel stays quiet.
    if (pending == null) {
      final missed = notifier.takePendingAutoFailure();
      if (missed != null && mounted) {
        showArulToast(context, missed.message, kind: ToastKind.error);
        setState(() => _outcome = _outcomeForFailure(missed.kind));
      }
      return;
    }

    setState(() => _signingIn = true);
    try {
      final result = await pending;
      if (!mounted) return;
      switch (result) {
        case AuthSuccess():
          context.go('/browse');
        case AuthCancelled(:final outcome):
          // No toast, but not a silent bounce -> the subtitle says what this attempt did.
          _outcome = outcome;
        case AuthFailure(:final message, :final kind):
          // Localized-enough surface + retry (the pill), never a stuck spinner.
          showArulToast(context, message, kind: ToastKind.error);
          _outcome = _outcomeForFailure(kind);
      }
      // Handled live here -> drop the recorded copy, or a later mount replays a seen failure.
      notifier.takePendingAutoFailure();
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  /// A visible failure already toasted its own message, so the subtitle only has to be TRUE.
  ///
  /// `noPlayServices` is the one failure with an actionable fix line — Credential Manager has no
  /// provider to ask, and no number of taps changes that. Everything else gets the plain retry
  /// line: the toast said what went wrong, and inventing a second, more specific claim here would
  /// be guessing.
  SignInOutcome _outcomeForFailure(AuthFailureKind kind) =>
      kind == AuthFailureKind.noPlayServices
      ? SignInOutcome.noProvider
      : SignInOutcome.backedOutQuick;

  void _onPillTap() {
    if (!AppConfig.hasBackend || !AppConfig.googleAuthConfigured) {
      // Unreachable in shipped builds — both defines are always set.
      // For define-less runs: browse is free and there is no Worker to exchange with -> pass through.
      context.go('/browse');
      return;
    }
    _signIn();
  }

  /// The language picker, from the footer.
  ///
  /// It is NOT part of the sign-in attempt and must never touch one: no `signIn`, no abandon, and
  /// it stays live while `_signingIn` — a user who cannot read the pill is exactly the user with an
  /// attempt in flight.
  /// The sheet follows the DEVICE's light/dark mode, not the app's saved theme mode: this screen is
  /// always dark over video whichever the user picked, so the app's own setting says nothing about
  /// what a sheet rising out of it should look like — the phone does.
  /// A session landing while the sheet is up still routes: `context.go` replaces the stack the
  /// sheet's route sits on, so the feed cannot arrive with a picker left over it.
  Future<void> _pickLanguage() async {
    ArulHaptics.tap();
    final current = appLanguageName(ref.read(localeProvider).languageCode);
    final picked = await showLanguageSheet(
      context,
      current,
      brightness: MediaQuery.platformBrightnessOf(context),
    );
    final code = picked == null ? null : appLanguageCodeFor(picked);
    if (code == null || !mounted) return;
    await ref.read(localeProvider.notifier).setLocale(Locale(code));
  }

  /// Opens the one out-of-app target this outcome offers.
  ///
  /// It must NEVER start or cancel a sign-in: the pill owns the attempt, and a help tap that
  /// silently re-launched Google would put a second surface up over the first.
  void _openHelp(_SignInHelpTarget target) {
    ArulHaptics.tap();
    final links = ref.read(signInHelpLinksProvider);
    unawaited(switch (target) {
      _SignInHelpTarget.accountSettings => links.openAccountSettings(),
      _SignInHelpTarget.playServices => links.openPlayServices(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final copy = _copyFor(l10n, _outcome);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Always-dark surface: status/nav icons stay light in both themes.
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: const Color(0x00000000),
        systemNavigationBarColor: const Color(0x00000000),
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: ArulTokens.darkSurface,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Same shared player as splash; we paint our own scrim below.
            const VideoBackground(overlayOpacity: 0),

            const DecoratedBox(
              decoration: BoxDecoration(gradient: ArulTokens.signInScrim),
            ),

            // Wordmark and tagline are the only things on bare artwork -> the only over-media shadows.
            // The scrim is only ~.29 this far down, which a bright sky walks straight through.
            Positioned(
              left: 0,
              right: 0,
              top: 112,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Arul',
                    textAlign: TextAlign.center,
                    style: ArulTokens.wordmarkSignIn.copyWith(
                      shadows: ArulTokens.overMediaShadow,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // At .42em the eyebrow measures ~364 and a 360dp phone breaks it over two lines.
                  // Two lines read as a heading, not a tracked rule of type -> shrink, never wrap.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _tagline,
                        maxLines: 1,
                        style: ArulTokens.tagline.copyWith(
                          shadows: ArulTokens.overMediaShadow,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // The language footer, under Google's own sign-in pages: the way OUT of a language the
            // user cannot read belongs at the foot of the page, not competing with the wordmark.
            // Left 20 lines it up with the silk panel's own inset. The bottom offset comes from the
            // MediaQuery inset, never a constant — a gesture bar and a 3-button nav bar are 24dp
            // apart and a fixed number buries it under one of them.
            // The scrim's 0.46 bottom stop is what grounds it; the size matrix pins that it stays
            // clear of the panel.
            Positioned(
              left: 20,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: _LanguageTrigger(
                key: kSignInLanguageTriggerKey,
                label: ref.watch(localeProvider).languageCode.toUpperCase(),
                semanticsLabel: l10n.settingsLanguage,
                onTap: _pickLanguage,
              ),
            ),

            // Everything readable or tappable sits on the panel -> legibility ignores the frame behind.
            // The artwork above and below stays uncovered — the whole point of a video back there.
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _SilkPanel(
                  key: kSignInPanelKey,
                  children: [
                    // Warmth, not instruction and not a feature list — the eyebrow and the pill
                    // already do those jobs, and a caption restating either read as three lines
                    // saying one thing. It says nothing about the trial on purpose: a billing
                    // detail, stated on `/premium`.
                    Text(
                      l10n.signInCaption,
                      textAlign: TextAlign.center,
                      style: ArulTokens.body.copyWith(
                        color: ArulTokens.ivory.withValues(alpha: 0.8),
                      ),
                    ),
                    // The only place the app narrates the wait -> it may claim only a wait it OWNS.
                    // Everything up to the credential happens under Google's surface.
                    ValueListenableBuilder<bool>(
                      valueListenable: SignInPhase.exchanging,
                      builder: (context, exchanging, _) => _SignInPill(
                        title: l10n.signInGoogle,
                        subtitle: exchanging
                            ? l10n.signInSubtitleExchanging
                            : copy.subtitle,
                        onTap: _signingIn ? () {} : _onPillTap,
                        busy: _signingIn,
                      ),
                    ),
                    // The explanation the one-line subtitle has no room for, and the one place the
                    // screen can hand the user something to DO about it.
                    if (copy.fix != null || copy.linkLabel != null)
                      _FixLine(
                        text: copy.fix,
                        linkLabel: copy.linkLabel,
                        onLink: copy.link == null
                            ? null
                            : () => _openHelp(copy.link!),
                      ),
                    const _TermsPrivacyLine(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pill title's type, shared with the language chip's label so the two controls cannot drift
/// apart on size, weight or colour — the chip adds only the over-media shadow it needs off-panel.
const TextStyle kSignInTitleStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: ArulTokens.ivory,
);

/// The language trigger's tap target. The size matrix reads its rect against [kSignInPanelKey]'s:
/// the two must never touch, and it must stay a 48dp target in every language and text size.
@visibleForTesting
const Key kSignInLanguageTriggerKey = Key('signIn.languageTrigger');

/// The silk panel, so the size matrix can measure the gap the footer has to live in.
@visibleForTesting
const Key kSignInPanelKey = Key('signIn.panel');

/// The pill's title box. Its CONSTRAINTS are the real slot; a child wider than the box it was given
/// is a title the safety net had to scale, which the size matrix forbids at text scale 1.0.
@visibleForTesting
const Key kSignInTitleKey = Key('signIn.pill.title');

/// The pill's subtitle line. The size matrix lays it out at its own constraints and counts lines:
/// exactly one at text scale 1.0 in every language, and never a truncation at any size.
@visibleForTesting
const Key kSignInSubtitleKey = Key('signIn.pill.subtitle');

/// The language footer: a 36dp chip carrying the `translate` glyph, the current language CODE and a
/// chevron — the shape of a control that opens a list, so it reads as tappable without competing
/// with the one thing on this screen that IS a button.
///
/// It shows the CODE (EN, TA, ML …), not the native name: two Latin capitals are the same width in
/// every language, so the chip never changes size or wraps, and a Malayalam speaker recognises "ML"
/// as fast as "മലയാളം" at a glance. Its label is the PILL TITLE'S style — [kSignInTitleStyle], the
/// same object, so the two cannot drift.
///
/// **The ground is matched to the pill's INTERIOR AS MEASURED, not to the pill's paint.** The pill
/// paints `rgba(20,9,12,.55)` over the silk panel in the bright middle of the artwork and its
/// interior reads ≈ rgb(44,27,21) on device. This chip sits on the scrim's darkest band, so the same
/// paint — alone, or with the panel's two layers under it — measured 7–9 luminance points darker and
/// read as a solid block beside a translucent pill (both tried on device). [_fill] is the 70% fill
/// that lands on the pill's interior over that band, measured 31 against the pill's 30 with the
/// water still faintly visible through it, exactly as the poster shows through the pill. Same
/// radius, same gold-50% border.
///
/// **The GLYPHS take no `shadows`.** `Icon` accepts them, and on device Impeller mis-offsets a
/// shadow drawn from an icon FONT: it painted a second dark `translate` mark ~13dp to the left of
/// the real one. Text shadows on the same screen (wordmark, eyebrow, this code) are correct — only
/// icons ghost. The chip's own ground is what keeps the glyphs legible here.
class _LanguageTrigger extends StatelessWidget {
  const _LanguageTrigger({
    super.key,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
  });

  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  /// Solved on device for the pill's measured interior over the scrim's bottom band (class doc).
  static const _fill = Color.fromRGBO(50, 22, 11, 0.70);

  static final _shape = BorderRadius.circular(ArulTokens.pillRadius);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // The chip is 36dp; the 48dp touch target is this padding around it, not chip height.
        // None on the left, so the chip's own edge lands on the 20dp margin the silk panel uses.
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 12, 6),
          child: Container(
            height: 36,
            padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
            decoration: BoxDecoration(
              color: _fill,
              borderRadius: _shape,
              border: Border.all(color: ArulTokens.goldBorder50, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Sized to the 15px label, not to the G mark's disc -> the glyph reads as part of
                // the word, the way the pill's title and subtitle read as one block.
                const Icon(Icons.translate, size: 16, color: ArulTokens.ivory),
                const SizedBox(width: 6),
                // The pill title's style, UNSHADOWED like the pill title: the ground is matched to
                // the pill's, so a media shadow here only fattened the glyphs against it.
                Text(label, maxLines: 1, style: kSignInTitleStyle),
                const SizedBox(width: 2),
                const Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: ArulTokens.gold,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The out-of-app targets a nudge may offer. Two, and there will never be a third: everything else
/// the user could "fix" is inside the Google flow the app cannot reach.
enum _SignInHelpTarget { accountSettings, playServices }

/// What the screen says about [outcome], resolved in ONE place so the subtitle, the explanation and
/// the link can never drift apart.
///
/// The pill subtitle is one 12px line in a ~182dp slot on a 360dp phone -> it carries the ACTION and
/// nothing else. Anything that needs a sentence goes to the fix line under the pill, which may wrap.
/// Rules the copy obeys: say only what this attempt actually did, separate the phone's wait from the
/// person's own hesitation, and never offer a link that cannot change the outcome.
({String subtitle, String? fix, String? linkLabel, _SignInHelpTarget? link})
_copyFor(AppLocalizations l10n, SignInOutcome? outcome) => switch (outcome) {
  null => (
    subtitle: l10n.signInSubtitleIdle,
    fix: null,
    linkLabel: null,
    link: null,
  ),
  // Google's surface came and went inside 8s -> the user closed it. Nothing to explain.
  SignInOutcome.backedOutQuick => (
    subtitle: l10n.signInNudgeBackedOutQuick,
    fix: null,
    linkLabel: null,
    link: null,
  ),
  // The wait was the PHONE'S. Telling this user to "try again" invites the second tap that opens a
  // second surface over the first -> the line asks for one tap and patience, and says why.
  SignInOutcome.backedOutSlow => (
    subtitle: l10n.signInNudgeBackedOutSlow,
    fix: l10n.signInFixBackedOutSlow,
    linkLabel: null,
    link: null,
  ),
  // No surface was ever seen -> "didn't go through" would be a lie about something the user did.
  SignInOutcome.neverOpened => (
    subtitle: l10n.signInNudgeNeverOpened,
    fix: null,
    linkLabel: null,
    link: null,
  ),
  // The user went looking for "add account". The fix is that they never needed one.
  SignInOutcome.addAccountAbandoned => (
    subtitle: l10n.signInNudgeAddAccount,
    fix: l10n.signInFixAddAccount,
    linkLabel: null,
    link: null,
  ),
  // Google refused to re-verify the account -> the repair is in the phone's own Google settings.
  SignInOutcome.reauthFailed => (
    subtitle: l10n.signInNudgeReauth,
    fix: l10n.signInFixReauth,
    linkLabel: l10n.signInLinkAccountSettings,
    link: _SignInHelpTarget.accountSettings,
  ),
  // GMS closed the window under us -> name what did it, and offer its listing.
  SignInOutcome.activityClosed => (
    subtitle: l10n.signInNudgeActivityClosed,
    fix: l10n.signInFixActivityClosed,
    linkLabel: l10n.signInLinkPlayServices,
    link: _SignInHelpTarget.playServices,
  ),
  // There is no provider to ask. The toast already said so -> the link is the whole fix line.
  SignInOutcome.noProvider => (
    subtitle: l10n.signInNudgeNoProvider,
    fix: null,
    linkLabel: l10n.signInLinkPlayStore,
    link: _SignInHelpTarget.playServices,
  ),
};

/// The sentence the pill subtitle has no room for, plus at most one gold link.
///
/// It WRAPS — uncapped, deliberately. A `maxLines` here would ellipsise a Malayalam explanation on
/// a 320dp phone, and an explanation cut in half is worse than no explanation.
/// The link is a separate tappable line, not an inline span: a `TapGestureRecognizer` inside a
/// `Text.rich` must be owned and disposed or it leaks, and an 11px inline word is too small to aim
/// at. The padding below IS the tap target.
class _FixLine extends StatelessWidget {
  const _FixLine({this.text, this.linkLabel, this.onLink});

  final String? text;
  final String? linkLabel;
  final VoidCallback? onLink;

  static const _text = TextStyle(
    fontSize: 11.5,
    height: 1.35,
    color: Color.fromRGBO(250, 245, 236, 0.5),
  );
  static const _link = TextStyle(
    fontSize: 11.5,
    height: 1.35,
    color: Color.fromRGBO(212, 160, 23, 0.85),
  );

  @override
  Widget build(BuildContext context) {
    final label = linkLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text != null)
          Text(text!, textAlign: TextAlign.center, style: _text),
        if (label != null)
          Semantics(
            link: true,
            label: label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onLink,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
                child: Text(label, textAlign: TextAlign.center, style: _link),
              ),
            ),
          ),
      ],
    );
  }
}

/// The one-tap pill: 56px, r999, `rgba(20,9,12,.55)` fill, gold-50% border, solid gold on press.
class _SignInPill extends StatefulWidget {
  const _SignInPill({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// In flight the trailing arrow becomes a spinner -> the post-picker Worker verify is not silent.
  final bool busy;

  @override
  State<_SignInPill> createState() => _SignInPillState();
}

class _SignInPillState extends State<_SignInPill> {
  static const _pillFill = Color.fromRGBO(20, 9, 12, 0.55);

  bool _pressed = false;

  void _setPressed(bool v) => setState(() => _pressed = v);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        ArulHaptics.tap();
        _setPressed(true);
      },
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: Container(
        // A MINIMUM, not a height. At the OS text sizes people run, a two-line block in six scripts
        // does not fit a fixed 56 (Devanagari sets ~40% taller per line and overflowed it by 2px at
        // 1.3x). The pill grows instead of clipping, and only when the subtitle actually wraps.
        constraints: const BoxConstraints(
          minHeight: ArulTokens.signInPillHeight,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: _pillFill,
          borderRadius: BorderRadius.circular(ArulTokens.pillRadius),
          border: Border.all(
            color: _pressed ? ArulTokens.gold : ArulTokens.goldBorder50,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: ArulTokens.ivory,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const _GoogleGMark(size: 20),
            ),
            const SizedBox(width: 12),
            // Both lines are written to FIT the slot at their own size, at text scale 1.0, in all
            // six scripts — that is the copy rule, and the size matrix is what enforces it. Neither
            // line is ever SHRUNK to make a translation fit: at 12px in Tamil or Malayalam a scaled
            // subtitle lands near 10px, on exactly the phones and readers this nudge exists for.
            // What each line does when the OS text size grows differs, because the two jobs differ:
            //   * the TITLE is a button label and must stay one line -> scaleDown, as a large-text
            //     safety net only; at 1.0 it is never scaled.
            //   * the SUBTITLE is a sentence -> it WRAPS to a second line and the pill grows.
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    key: kSignInTitleKey,
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      style: kSignInTitleStyle,
                    ),
                  ),
                  Text(
                    widget.subtitle,
                    key: kSignInSubtitleKey,
                    // TWO lines is the design budget on a 360dp phone: a line that fits at 1.0
                    // needs at most 1.3 slots at 1.3. The third exists for the 320dp frame the
                    // l10n envelope gates on, where the slot is 140dp and wrapping is limited by
                    // WORD boundaries — Tamil's "Google வரவில்லை, தட்டவும்" is three chunks that
                    // no two lines can hold. No ellipsis anywhere: nothing on this screen truncates.
                    maxLines: 3,
                    style: TextStyle(
                      fontSize: 12,
                      color: ArulTokens.ivory.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: ArulTokens.gold,
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Icon(
                  Icons.arrow_forward,
                  size: 22,
                  color: ArulTokens.gold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The silk panel: the one surface everything readable or tappable sits on.
///
/// Two ordinary paints — [ArulTokens.mediaFillStrong] as the ground, [ArulTokens.silkDark] over it.
/// NOT a `BackdropFilter`: blur costs ~6–9ms of raster per frame at a usable sigma.
/// On budget SoCs that comes straight out of the video decoder's budget (ui-direction §Perf).
/// Stacked gradients cost nothing and read richer over full-bleed photography anyway.
class _SilkPanel extends StatelessWidget {
  const _SilkPanel({super.key, required this.children});

  final List<Widget> children;

  static final _radius = BorderRadius.circular(ArulTokens.cardRadius);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArulTokens.mediaFillStrong,
        borderRadius: _radius,
        border: Border.all(color: ArulTokens.goldBorder40, width: 1),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: ArulTokens.silkDark,
          borderRadius: _radius,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 13),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 'Terms · Privacy', 11px, faint ivory, gold-85% links.
///
/// A [TapGestureRecognizer] must be owned and disposed by a stateful widget or it leaks.
/// So this is a Row of two tappable children, not one `Text.rich` with spans.
/// 11px glyphs are far too small to aim at -> the padding below is the TAP TARGET, not spacing.
class _TermsPrivacyLine extends StatelessWidget {
  const _TermsPrivacyLine();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // This sits on the silk panel, not the wallpaper -> a shadow on a solid ground reads as fuzz.
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _PolicyLink(label: l10n.signInTermsLink, doc: PolicyDoc.terms),
        const Text(' · ', style: _policyBase),
        _PolicyLink(label: l10n.signInPrivacyLink, doc: PolicyDoc.privacy),
      ],
    );
  }
}

const _policyBase = TextStyle(
  fontSize: 11,
  color: Color.fromRGBO(250, 245, 236, 0.5),
);
const _policyLink = TextStyle(
  fontSize: 11,
  color: Color.fromRGBO(212, 160, 23, 0.85),
);

/// One policy link, opening the in-app reader.
///
/// The same pages are linked from the Settings footer and named in the Play listing.
/// Three copies of a policy URL is how one goes stale -> the URLs come from [AppConfig]/[PolicyDoc].
class _PolicyLink extends StatelessWidget {
  const _PolicyLink({required this.label, required this.doc});

  final String label;
  final PolicyDoc doc;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => ArulHaptics.tap(),
        // Pushed OVER this screen and popping back -> sign-in is never left behind in another app.
        // Safe mid-auth: the one-shot authenticate() already launched, and returning does not re-arm.
        onTap: () => context.push(doc.route),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 3),
          child: Text(label, style: _policyLink),
        ),
      ),
    );
  }
}

/// The Google "G" — Google's OWN asset, NEVER a redraw.
///
/// The branding guidelines require the standard colour version, unchanged in size or colour.
/// "Create your own icon for the button" is listed under Don't.
/// `assets/images/google_g.webp` is Google's own `g-logo.png`, padded square, lossless at 96px.
/// The 20dp slot needs ≤80px even at 4x.
/// It sits on the pill's ivory disc — the guidelines' white-background requirement.
class _GoogleGMark extends StatelessWidget {
  const _GoogleGMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/google_g.webp',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    );
  }
}
