import 'package:arul/features/premium/domain/post_signin_paywall.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => PostSigninPaywall.take());

  test('only the paywall side opens anything', () {
    PostSigninPaywall.note('control');
    expect(PostSigninPaywall.take(), isFalse);
    PostSigninPaywall.note(null);
    expect(PostSigninPaywall.take(), isFalse);
  });

  test('the paywall side opens exactly once', () {
    PostSigninPaywall.note('paywall');
    expect(PostSigninPaywall.take(), isTrue);
    expect(PostSigninPaywall.take(), isFalse);
  });

  test('a later sign-in outside the test clears a pending one', () {
    PostSigninPaywall.note('paywall');
    PostSigninPaywall.note(null);
    expect(PostSigninPaywall.take(), isFalse);
  });
}
