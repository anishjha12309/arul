# Local stack — test on the phone without touching production

Worker, CDN and CMS run on this PC; the USB phone reaches them over `adb reverse`. Data = Neon **debug**
branch + **local** R2 on disk. Release/prod APKs keep using `env/prod.json` and are unaffected: nothing
here edits `main` resources, `prod.json` or `wrangler.toml`.

> **The seed never reaches production**: it refuses any non-local R2 target and any database but the debug
> branch. The clips are third-party (scraped from the Crafto app); which of them go to prod is the owner's
> call, through `tools/status-import.mjs` ([status-clips.md](status-clips.md)).

## What runs where

| Piece | Port | Notes |
|---|---|---|
| Arul Worker | 8787 | `wrangler dev --local`, Hyperdrive = debug branch, PostHog blackholed, `PUSH_ENABLED=false` |
| Local CDN | 8788 | `workers/tools/local-cdn`: local R2 first, else read-only proxy of `arul-cdn.hsrutility.com` |
| CMS | 8790 | `C:\Anish\Unified CMS` via its `npm run dev:local`; `ARUL_API` binds to the local Worker (shared dev registry) |

State, logs (`logs/*.log`) and the registry live in `C:\Anish\Arul\.wrangler\local-stack` (git-ignored).
Signed URLs from the local Worker point at `http://127.0.0.1:8788/__s3/...`, so Save/Share downloads hit
local R2 too. Wallpapers and ringtones still work: missing keys stream from the real CDN.

Every tool fails closed: `--remote` is refused outright, a database is opened only when its endpoint is
the debug branch's, and the local CDN answers loopback GET/HEAD only. **Never `wrangler deploy` from
`local-cdn/`** — its R2 binding names the production bucket on purpose (miniflare keys local state by
bucket name, so the Worker and the CDN share one local bucket).

**`up` writes `.wrangler/local-stack/worker.env` = `workers/.dev.vars` + the CMS's
`ARUL_CATALOG_BUILD_SECRET` as `CATALOG_BUILD_SECRET`**, and hands it to the Worker with `--env-file`.
Wrangler's `--env-file` REPLACES `.dev.vars` rather than layering on it, hence the full copy; without the
CMS's secret a local CMS publish cannot rebuild the local catalog. `down` deletes the file. The seed's
`--build-only` reads the secret from it first, then from `.dev.vars`.

## Steps

1. Prereqs: `ffmpeg`/`ffprobe` on PATH, `adb`, `env/dev.json`, `workers/.dev.vars` with
   `DEBUG_DATABASE_URL` and `PHONEPE_ENV=SANDBOX` (`up` refuses otherwise), the CMS's `.env` Hyperdrive
   strings on the debug branch (or pass `--no-cms`), phone on USB with debugging on (`adb devices` lists
   one; else `export ANDROID_SERIAL=<serial>`).
2. `cd workers && node tools/local-stack.mjs up` — writes `env/local.json`, starts all three, runs both
   `adb reverse`s, prints health (`/me` → 401, CDN `version.json` and `statuses/all_1.json`). Plug the
   phone in first or re-run `up`.
3. `node tools/local-seed-statuses.mjs --count 40` — first run encodes ~20 s per clip (cached after),
   puts them in local R2, upserts debug rows + `status` categories, sets `status_tab=true`, bumps
   `content_version` and rebuilds the local catalog. Re-running is safe (same ids and keys).
   Preview first: `--dry-run` (2 clips to a temp dir + the SQL, writes nothing). It refuses until
   `db/schema/30_statuses.sql` is applied to the debug branch.
4. From the repo root: `flutter run --dart-define-from-file=env/local.json` (debug build). If a Play or
   newer build is installed, `flutter run` uninstalls it silently — you will sign in again.
5. Iterate: `r` hot reload, `R` hot restart. Backend change → it reloads itself (wrangler watches `src/`).
6. Sign in with Google once (creates your user on the debug branch).
7. Premium on/off for the gated actions: `node tools/local-premium.mjs grant <email>` / `revoke <email>`
   / `status <email>` — it sets `users.reward_premium_until`, so a live debug subscription row still
   grants premium after a revoke. The gate reads it live; reopen the app for the badge.
8. Flag on/off: `node tools/local-seed-statuses.mjs --flag off` (or `on`). Takes effect on the next cold
   start (swipe the app away, reopen).
9. Rebuild the catalog after any manual DB edit: `node tools/local-seed-statuses.mjs --build-only`.
10. Old build must show no Status: `git worktree add ../arul-92 83d10fd` (build 92), then in it
    `flutter pub get && flutter build apk --debug --split-per-abi --dart-define-from-file=../Arul/env/local.json`,
    `adb uninstall com.hsrutility.arul`, `adb install build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`
    (read the full output for `Success`). With `status_tab=true` it must show the old dock, wallpapers and
    ringtones as before. Remove it after: `git worktree remove ../arul-92`.
11. Teardown: `node tools/local-stack.mjs down` (stops all three, drops the reverses and `worker.env`).
    Local R2 and the encode cache stay in the persist dir; delete the folder to start clean. `status`
    shows what is up.

## Limits

- Without the CMS's `dev:local` script, `up` falls back to plain `wrangler dev --local`: its `.dev.vars`
  `CMS_ENV=dev` then skips the rebuild trigger and its presigned uploads go to the remote dev bucket,
  not local R2 — publish from the CMS, then run step 9.
- A debug run still sends client analytics (PostHog, GA4, Meta), exactly like `env/dev.json`.
- Crons never fire on their own; rehearse one with `node tools/cron-rehearse.mjs`.
- Cleartext is allowed to `127.0.0.1`/`localhost` only in debug builds
  (`android/app/src/debug/res/xml/network_security_config.xml` overrides the deny-all `main` one).
