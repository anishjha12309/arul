/**
 * Unit tests for CMS admin password verification (PBKDF2, Web Crypto).
 * Uses a low iteration count for speed; verifyPassword reads the count from the
 * stored digest, so it stays compatible.
 */

import { describe, it, expect } from "vitest";
import { verifyPassword } from "../src/admin/auth.js";

function b64(u: Uint8Array): string {
  return btoa(String.fromCharCode(...u));
}

async function makeHash(password: string, iterations = 1000): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
      key,
      32 * 8,
    ),
  );
  return `pbkdf2$${iterations}$${b64(salt)}$${b64(bits)}`;
}

describe("verifyPassword", () => {
  it("accepts the correct password", async () => {
    const hash = await makeHash("correct horse battery");
    expect(await verifyPassword("correct horse battery", hash)).toBe(true);
  });

  it("rejects the wrong password", async () => {
    const hash = await makeHash("correct horse battery");
    expect(await verifyPassword("wrong password", hash)).toBe(false);
  });

  it("rejects malformed or empty digests", async () => {
    expect(await verifyPassword("x", "")).toBe(false);
    expect(await verifyPassword("x", "not-a-hash")).toBe(false);
    expect(await verifyPassword("x", "pbkdf2$abc$salt$hash")).toBe(false);
    expect(await verifyPassword("x", "bcrypt$1000$a$b")).toBe(false);
  });
});
