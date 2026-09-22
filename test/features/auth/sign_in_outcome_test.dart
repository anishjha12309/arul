// The screen shows ONE line per failed attempt, so every branch here is a sentence a real user
// reads. A wrong branch is not a wrong metric, it is a lie on screen -> every message observed in
// the field is pinned by name, in both of Google's spellings, and every unknown falls to the one
// line that is always true.

import 'package:arul/features/auth/domain/sign_in_outcome.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SignInOutcome classify({
    String? description,
    int? msSinceAuthenticate = 4000,
    int? msToSurface = 1200,
  }) => classifySignInOutcome(
    description: description,
    msSinceAuthenticate: msSinceAuthenticate,
    msToSurface: msToSurface,
  );

  group('messages that name their own cause', () {
    test('the add-account walkout is its own outcome', () {
      for (final message in const [
        '[16] User cancelled during add account flow and accounts were present.',
        '[16] User canceled during add account flow and accounts were present.',
      ]) {
        expect(
          classify(description: message),
          SignInOutcome.addAccountAbandoned,
          reason: message,
        );
      }
    });

    test('a failed re-auth is its own outcome', () {
      expect(
        classify(description: '[16] Account reauth failed.'),
        SignInOutcome.reauthFailed,
      );
    });

    test('a closed activity is GMS, not the user', () {
      for (final message in const [
        'activity is cancelled by the user.',
        'activity is canceled by the user.',
        // The same message reaches us without its full stop from other builds.
        'activity is cancelled by the user',
      ]) {
        expect(
          classify(description: message),
          SignInOutcome.activityClosed,
          reason: message,
        );
      }
    });

    test('a cause-naming message ignores the clocks entirely', () {
      // Timing must never override a message that already said what happened.
      expect(
        classify(description: '[16] Account reauth failed.', msToSurface: null),
        SignInOutcome.reauthFailed,
      );
      expect(
        classify(
          description: '[16] Account reauth failed.',
          msToSurface: 30000,
        ),
        SignInOutcome.reauthFailed,
      );
    });
  });

  group('the backed-out family, split by the wait for Google', () {
    const backedOut = [
      '[16] Cancelled by user.',
      '[16] Canceled by user.',
      'User cancelled the selector',
      'User canceled the selector',
      // Legacy builds sent no description at all.
      null,
    ];

    test('a surface that came up fast means the user closed it', () {
      for (final message in backedOut) {
        expect(
          classify(description: message, msToSurface: 1200),
          SignInOutcome.backedOutQuick,
          reason: '$message',
        );
      }
    });

    test('a surface that took 8s or more means the PHONE was slow', () {
      for (final message in backedOut) {
        expect(
          classify(description: message, msToSurface: 9000),
          SignInOutcome.backedOutSlow,
          reason: '$message',
        );
      }
    });

    test('no surface ever seen is neither — Google returned on its own', () {
      for (final message in backedOut) {
        expect(
          classify(description: message, msToSurface: null),
          SignInOutcome.neverOpened,
          reason: '$message',
        );
      }
    });

    test('8000ms is the edge, and it belongs to slow', () {
      expect(classify(msToSurface: 7999), SignInOutcome.backedOutQuick);
      expect(classify(msToSurface: 8000), SignInOutcome.backedOutSlow);
      expect(kSlowSurfaceMs, 8000);
    });

    test('0ms is quick, not missing', () {
      expect(classify(msToSurface: 0), SignInOutcome.backedOutQuick);
    });
  });

  group('anything we cannot prove', () {
    test('an unknown message never invents a reason', () {
      for (final message in const [
        'Unable to get sync account',
        '[28404] Failed to retrieve an ID token',
        'PlatformException(sign_in_failed, ...)',
        '',
        '   ',
      ]) {
        expect(
          classify(description: message),
          SignInOutcome.backedOutQuick,
          reason: message,
        );
      }
    });

    test('an unknown message stays quick even with no surface reading', () {
      // Only the backed-out family may claim `neverOpened` — that claim is about a message we
      // recognise, not about a null clock.
      expect(
        classify(description: 'Unable to get sync account', msToSurface: null),
        SignInOutcome.backedOutQuick,
      );
    });

    test('surrounding whitespace does not change the verdict', () {
      expect(
        classify(description: '  [16] Account reauth failed.  '),
        SignInOutcome.reauthFailed,
      );
    });

    test(
      'ms_since_authenticate is carried, never consulted — the clock starts at '
      'the auto-launch, so it cannot split these',
      () {
        for (final elapsed in const [null, 0, 500, 45000]) {
          expect(
            classify(msSinceAuthenticate: elapsed, msToSurface: 1200),
            SignInOutcome.backedOutQuick,
            reason: 'elapsed=$elapsed',
          );
        }
      },
    );
  });
}
