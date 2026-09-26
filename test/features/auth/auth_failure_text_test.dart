// The wall's failure toast is the app's language, one line per kind — never the failure's own
// English message, which for a server failure is the Worker's text.

import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';

import 'package:arul/app/l10n/app_localizations.dart';
import 'package:arul/features/auth/domain/auth_service.dart';
import 'package:arul/features/auth/presentation/sign_in_screen.dart';

void main() {
  test('every kind has a line in every locale, and Tamil is not English', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final code in const ['hi', 'ta', 'te', 'kn', 'ml']) {
      final l10n = lookupAppLocalizations(Locale(code));
      for (final kind in AuthFailureKind.values) {
        final text = authFailureText(l10n, kind);
        expect(text, isNotEmpty);
        expect(
          text,
          isNot(authFailureText(en, kind)),
          reason: '$code/$kind fell back to English',
        );
      }
    }
  });
}
