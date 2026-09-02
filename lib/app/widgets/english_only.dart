import 'package:flutter/widgets.dart';

/// Renders [child] in English no matter which locale the app is in.
///
/// The overflow matrix demotes an overflowing translation one KEY at a time
/// (`tools/l10n/demoted_translations.json`) -> a surface reads half-translated ("வால்பேப்பர்கள் ·
/// Ringtones · அமைப்புகள்" on a Tamil dock) -> owner's call: one demoted string sends the WHOLE
/// section English.
/// The sections are the dock, Reminders and Upload — picked one by one, NOT every screen with a
/// demoted key; the settings list, refer, the error cards and the ringtone row stay mixed by that
/// same call.
/// `Localizations.override` is the mechanism on purpose -> it re-resolves `AppLocalizations.of` AND
/// the Material/Cupertino strings for every descendant, including a `State.context` read from inside
/// the subtree (a toast, a dialog the screen raises).
/// Restoring the demoted keys in the ARBs brings the overflows back; reaching around this wrapper
/// with `lookupAppLocalizations` would miss the descendants.
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
