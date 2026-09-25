/// What actually happened to a sign-in attempt that ended without a session.
///
/// The screen shows ONE line about it, so that line must be TRUE and SPECIFIC: `login_cancelled`
/// is a mixed bucket (docs/auth.md §Reading the failure buckets) and a single "try again" nudge
/// told a user whose Play services closed the window the same thing as a user who tapped Back.
/// Two different people, one useless sentence.
///
/// The split that matters is the PHONE'S wait versus the PERSON'S hesitation: Google's surface
/// taking 8s to draw is not the same event as a user closing it in 2s, and only the second is a
/// choice. Everything here is derived from evidence the attempt actually produced — the Credential
/// Manager message and the two clocks. Nothing is inferred: an unrecognised message means we do not
/// know, and "we do not know" is [backedOutQuick]'s plain retry line.
library;

/// The outcomes the sign-in screen can speak to. `name` is what analytics carries as `nudge`.
enum SignInOutcome {
  /// A dismissal with Google's surface already up and gone inside [kSlowSurfaceMs].
  /// Also the honest default for anything unrecognised -> a plain retry claims nothing.
  backedOutQuick,

  /// Google's surface took [kSlowSurfaceMs] or more to appear. The user waited on the PHONE,
  /// not on themselves — so the line is about the wait, and a second tap only restarts it.
  backedOutSlow,

  /// No Google surface was ever seen: Credential Manager returned a cancel on its own.
  neverOpened,

  addAccountAbandoned,

  /// Google could not re-verify the chosen account. Nothing the app can fix -> point at Settings.
  reauthFailed,

  /// The sign-in Activity was closed under us — GMS, not the user.
  activityClosed,

  /// Credential Manager has no provider on this phone (`providerConfigurationError`).
  /// Routed on the failure KIND, never classified from a message.
  noProvider,

  /// Credential Manager closed a BUTTON-flow session the user never touched. An app-icon launch
  /// on the live task (`clearTaskOnLaunch`) finished Google's picker under us; the framework
  /// reports that as "User cancelled the selector", where a real back-out says "[16] Cancelled by
  /// user". Not a cancellation -> the guard relaunches once. Assigned by the service, never by
  /// [classifySignInOutcome], which has no surface to read.
  selectorStripped,
}

/// Where "the surface appeared quickly" ends, in milliseconds since `authenticate()`.
///
/// Under this the app was waiting on a person; at or over it the person was waiting on Google.
/// The device gradient behind the number: Google's credential step measured ~13s on a current
/// phone and 23-36s on entry-level ones, so a surface still not drawn at 8s is the phone.
const int kSlowSurfaceMs = 8000;

/// Credential Manager messages, normalised (trimmed, one trailing full stop optional).
///
/// Both spellings are listed because Google ships both: `User canceled the selector` and
/// `User cancelled the selector` arrive from the same builds in the same week.
const Map<String, SignInOutcome> _knownMessages = <String, SignInOutcome>{
  '[16] User cancelled during add account flow and accounts were present':
      SignInOutcome.addAccountAbandoned,
  '[16] User canceled during add account flow and accounts were present':
      SignInOutcome.addAccountAbandoned,
  '[16] Account reauth failed': SignInOutcome.reauthFailed,
  'activity is cancelled by the user': SignInOutcome.activityClosed,
  'activity is canceled by the user': SignInOutcome.activityClosed,
};

const Set<String> _backedOutMessages = <String>{
  '[16] Cancelled by user',
  '[16] Canceled by user',
  'User cancelled the selector',
  'User canceled the selector',
};

/// Classifies one ended-without-a-session attempt. Pure -> every string below is pinned by tests.
///
/// [description] is the Credential Manager message (`login_cancelled.description`). Null is a
/// legacy shape and is read as the backed-out family, split like any other.
/// [msToSurface] is the wall-clock from `authenticate()` to the first inactive/paused/hidden of the
/// attempt — Google's surface coming up over ours. Null means no surface was ever seen.
/// [msSinceAuthenticate] is recorded for the event and decides NOTHING: timing alone under-splits,
/// because the clock starts at the auto-launch and a scripted dismissal lands inside the failure
/// band (docs/auth.md).
SignInOutcome classifySignInOutcome({
  String? description,
  int? msSinceAuthenticate,
  int? msToSurface,
}) {
  final message = _normalise(description);

  if (message != null) {
    final known = _knownMessages[message];
    if (known != null) return known;
    if (!_backedOutMessages.contains(message)) {
      // An unrecognised message proves nothing -> say the one thing that is always true.
      return SignInOutcome.backedOutQuick;
    }
  }

  if (msToSurface == null) return SignInOutcome.neverOpened;
  return msToSurface < kSlowSurfaceMs
      ? SignInOutcome.backedOutQuick
      : SignInOutcome.backedOutSlow;
}

/// Trim, then drop ONE trailing full stop: the same message reaches us with and without it
/// (`activity is cancelled by the user` in one build, `...user.` in the next).
String? _normalise(String? description) {
  if (description == null) return null;
  final trimmed = description.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}
