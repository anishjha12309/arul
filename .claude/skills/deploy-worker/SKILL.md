---
name: deploy-worker
description: Deploy the Arul Cloudflare Worker (workers/) to production. Use after ANY workers/ change — deploy is part of "done". Runs checks, deploys as admin@hsrutility.com, verifies live.
---

# Deploy Worker

0. Precondition: `workers/wrangler.toml` contains no `TODO_` placeholder — otherwise provisioning
   (docs/provisioning.md) is incomplete; STOP and tell the user what's missing.
1. Check: `cd workers && npx tsc --noEmit && npx vitest run` — both green or STOP.
2. Verify account: `npx wrangler whoami` must show **admin@hsrutility.com** (account
   `ba8dd87179e2ffd378a50292ca8e69e0`). Wrong/no account → tell user to `wrangler login` as admin
   (error 10000 = wrong account).
3. Deploy: `npx wrangler deploy`. Record the version id — report it.
4. Verify live (custom domains `arul-api` / `arul-cdn.hsrutility.com` are NOT attached yet — they
   NXDOMAIN, so use the real origins):
   - Any route: `curl -s https://arul-api.twilight-smoke-d495.workers.dev/nonexistent` → JSON 404 envelope proves the Worker answers.
   - Content-affecting change: `curl -X POST https://arul-api.twilight-smoke-d495.workers.dev/internal/build-catalog -H "Authorization: Bearer $CATALOG_BUILD_SECRET"` then check `https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev/catalog/version.json`.
5. Secrets changed? `npx wrangler secret put <NAME>` (full list: workers/README.md). Never echo secret values.

Never deploy with failing tsc/tests. Cron changes ship with the deploy automatically (wrangler.toml).
