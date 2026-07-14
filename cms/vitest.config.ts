import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // "happy-dom" provides the Web APIs (crypto.subtle, TextEncoder, btoa, …)
    // the Worker code relies on, without pulling in the full Workers runtime.
    environment: "happy-dom",
    globals: false,
    include: ["test/**/*.test.ts"],
  },
});
