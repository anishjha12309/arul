/**
 * Safety test for the local-dev PhonePe base-URL override.
 *
 * PHONEPE_BASE_URL_OVERRIDE exists so the autopay billing path can be driven to
 * a TERMINAL redemption state locally (PhonePe's UAT sandbox holds redemptions
 * PENDING, so COMPLETED/FAILED are otherwise only reachable on the live gateway
 * with real money). That makes it a var which, if it were ever honoured in
 * production, would point real ₹199 debits at an attacker-chosen host.
 *
 * The guarantee under test: on PRODUCTION the override is not merely unused, it
 * is unreachable — the production host is returned before the var is read.
 */

import { describe, it, expect } from "vitest";
import { getPgBase } from "../src/lib/phonepe.js";
import type { Env } from "../src/env.js";

const PROD_HOST = "https://api.phonepe.com/apis/pg";
const SANDBOX_HOST = "https://api-preprod.phonepe.com/apis/pg-sandbox";

function env(partial: Partial<Env>): Env {
  return partial as Env;
}

describe("getPgBase — production can never be redirected", () => {
  it("ignores the override entirely when PHONEPE_ENV=PRODUCTION", () => {
    expect(
      getPgBase(
        env({
          PHONEPE_ENV: "PRODUCTION",
          PHONEPE_BASE_URL_OVERRIDE: "http://127.0.0.1:8799",
        }),
      ),
    ).toBe(PROD_HOST);
  });

  it("ignores even a plausible-looking hostile override on PRODUCTION", () => {
    expect(
      getPgBase(
        env({
          PHONEPE_ENV: "PRODUCTION",
          PHONEPE_BASE_URL_OVERRIDE: "https://api-phonepe.attacker.example/apis/pg",
        }),
      ),
    ).toBe(PROD_HOST);
  });

  it("uses the real sandbox when no override is set", () => {
    expect(getPgBase(env({ PHONEPE_ENV: "SANDBOX" }))).toBe(SANDBOX_HOST);
  });

  it("an empty-string override falls back to the sandbox, never to ''", () => {
    expect(
      getPgBase(env({ PHONEPE_ENV: "SANDBOX", PHONEPE_BASE_URL_OVERRIDE: "" })),
    ).toBe(SANDBOX_HOST);
  });

  it("honours the override only in a non-production env", () => {
    expect(
      getPgBase(
        env({
          PHONEPE_ENV: "SANDBOX",
          PHONEPE_BASE_URL_OVERRIDE: "http://127.0.0.1:8799",
        }),
      ),
    ).toBe("http://127.0.0.1:8799");
  });

  it("case/whitespace variants of PRODUCTION still resolve to the prod host, override ignored", () => {
    // Arul's isProduction() trims + uppercases (a "Production" secret means
    // production), so the override must be unreachable for those variants too.
    expect(
      getPgBase(
        env({ PHONEPE_ENV: "Production", PHONEPE_BASE_URL_OVERRIDE: "http://127.0.0.1:8799" }),
      ),
    ).toBe(PROD_HOST);
    expect(getPgBase(env({ PHONEPE_ENV: " PRODUCTION\n" }))).toBe(PROD_HOST);
  });

  it("garbage PHONEPE_ENV throws loudly instead of silently picking a host", () => {
    // Arul delta vs the reference app: isProduction() THROWS on anything that
    // is not PRODUCTION/SANDBOX — a typo must fail loudly, never downgrade.
    expect(() => getPgBase(env({ PHONEPE_ENV: "prod" }))).toThrow(/PHONEPE_ENV/);
    expect(() => getPgBase(env({ PHONEPE_ENV: "" }))).toThrow(/PHONEPE_ENV/);
  });
});
