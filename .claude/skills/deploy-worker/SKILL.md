---
name: deploy-worker
description: Deploy the Arul Cloudflare Worker (workers/) to production. Use after ANY workers/ change — deploy is part of "done". Runs checks, deploys as admin@hsrutility.com, verifies live.
---

# Deploy Worker

0. Precondition: `workers/wrangler.toml` contains no `TODO_` placeholder — otherwise provisioning
   (docs/provisioning.md) is incomplete; STOP and tell the user what's missing.
1. Check: `cd workers && npx tsc --noEmit && npx vitest run` — both green or STOP.
2. Account: `npx wrangler whoami` must show **admin@hsrutility.com** (account
   `ba8dd87179e2ffd378a50292ca8e69e0`). Wrong/no account → tell the user to `wrangler login` as admin
   (error 10000 = wrong account).
3. Deploy: `npx wrangler deploy`. Record the version id — report it.
4. Confirm it answers live. Both hostnames are the same deploy and both must keep working:
   `arul-api.hsrutility.com` is the `custom_domain` route wrangler owns, and
   `arul-api.twilight-smoke-d495.workers.dev` still serves every already-installed build
   (`workers_dev = true` is load-bearing — dropping it silently kills those installs).
   ```bash
   curl -s https://arul-api.hsrutility.com/nonexistent          # JSON 404 envelope = alive
   ```
   Content-affecting change? Rebuild and read the pointer — with **GET, never `curl -I`**; HEAD
   reports `DYNAMIC` for assets that cache fine (docs/caching.md):
   ```bash
   curl -X POST https://arul-api.hsrutility.com/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"
   curl -s https://arul-cdn.hsrutility.com/catalog/version.json
   ```
5. Secrets changed? `npx wrangler secret bulk <file.json>` — **never a shell pipe**: a trailing
   newline in `PHONEPE_ENV` routes production credentials to the sandbox host and the resulting 401
   is indistinguishable from bad credentials. Full list: workers/README.md. Never echo a value.
   `OPS_SECRET` gates the money-moving internal routes (`run-redemptions`, `refund`) and fails closed
   when unset — that is the safe state, so leave it unset unless an operator run needs it.
6. Deploying does not restart anything on the app side, but it DOES ship cron changes: both triggers
   in `[triggers]` (`0 * * * *` hourly, `30 21 * * *` daily sweep) come from wrangler.toml, so a
   removed line silently removes a cron. Cron behaviour: docs/cron.md.

Never deploy with failing tsc/tests.
