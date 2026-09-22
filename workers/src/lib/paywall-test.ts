/**
 * The after-sign-in paywall test -> which side a brand-new account lands on.
 *
 * The side is a pure function of the account id, fixed at creation -> a reinstall can never flip it
 * A v4 UUID's last hex digit is random -> even/odd is a fair 50/50 with no state and no second write
 * Stored on users.paywall_test (db/schema/24_paywall_test.sql) -> the read never recomputes it
 */

export type PaywallTestSide = "paywall" | "control";

export function paywallTestSide(userId: string): PaywallTestSide {
  const last = Number.parseInt(userId.slice(-1), 16);
  return last % 2 === 0 ? "paywall" : "control";
}
