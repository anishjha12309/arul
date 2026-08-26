import 'package:flutter/widgets.dart';

/// Renders [child] in English no matter which locale the app is in.
///
/// The l10n overflow matrix demotes a translation that overflows its slot to
/// English one KEY at a time (`tools/l10n/demoted_translations.json`), which
/// leaves a surface half-translated: the dock read "வால்பேப்பர்கள் · Ringtones ·
/// அமைப்புகள்" on a Tamil phone. Owner's call, 2026-08-25: a section that
/// carries one demoted string reads worse mixed than fully English, so the
/// WHOLE section goes English. The sections are the dock, the Reminders screen
/// and the Upload screen — chosen one by one, not every screen with a demoted
/// key (the settings list, refer, the error cards and the ringtone row stay
/// mixed by that same call).
///
/// `Localizations.override` is the mechanism on purpose: it re-resolves
/// `AppLocalizations.of(context)` AND the Material/Cupertino strings for every
/// descendant, and a `State.context` read from inside the subtree (a toast, a
/// dialog raised by the screen) resolves through it too. Restoring the demoted
/// keys in the ARBs would bring the overflows back; translating around this
/// wrapper with `lookupAppLocalizations` would miss the descendants.
class EnglishOnly extends StatelessWidget {
  const EnglishOnly({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Localizations.override(
      context: context,
      locale: const Locale('en'),
      child: child,
    );
  }
}
