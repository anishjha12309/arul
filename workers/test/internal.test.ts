/**
 * Unit tests for the internal build-catalog auth gate. Only the bearer-secret
 * authorization is exercised here; the success path runs buildCatalog (live DB +
 * R2) and is covered structurally by catalog.test.ts.
 */

import { describe, it, expect } from "vitest";
import { makeEnv, makeCtx } from "./_ctx.js";
import { handleBuildCatalog } from "../src/routes/internal.js";

describe("POST /internal/build-catalog — auth gate", () => {
  it("401 when no Authorization header is present", async () => {
    const env = makeEnv({ CATALOG_BUILD_SECRET: "s3cret" });
    const res = await handleBuildCatalog(makeCtx({ env, jsonBody: {} }));
    expect(res.status).toBe(401);
  });

  it("401 when the bearer secret is wrong", async () => {
    const env = makeEnv({ CATALOG_BUILD_SECRET: "s3cret" });
    const res = await handleBuildCatalog(
      makeCtx({ env, token: "wrong-secret", jsonBody: {} }),
    );
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("unauthorized");
  });
});
