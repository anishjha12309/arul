import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Use the "happy-dom" environment to provide Web APIs (crypto.subtle,
    // TextEncoder, btoa, etc.) that the Worker code relies on.
    // This avoids pulling in @cloudflare/vitest-pool-workers for unit tests
    // that don't need the full Workers runtime.
    environment: "happy-dom",
    globals: false,
    include: ["test/**/*.test.ts"],
  },
});
