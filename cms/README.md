# hsr-cms — unified CMS Worker (Pakiza + Arul)

One standalone Cloudflare Worker (Hono JSX + HTMX, server-rendered, no client
build step) that manages content for **both** apps from a single login:

- **Pakiza** — Islamic wallpapers + ringtones (`api.hsrutility.com`)
- **Arul** — South Indian wallpapers (`arul-api.twilight-smoke-d495.workers.dev`)

The per-app Workers keep their own crons (hourly rebuild + orphan sweeps); this
Worker only authors content and *triggers* rebuilds over HTTP. It never serves
app traffic.

## App registry (`src/registry.ts`)

Every route module receives an `AppDef` and reaches its DB / R2 / API
**exclusively** through it — an `/arul/*` mutation is structurally unable to
touch a Pakiza binding and vice versa (`test/isolation.test.ts` proves it).

| | pakiza | arul |
|---|---|---|
| Hyperdrive binding | `HYPERDRIVE_PAKIZA` | `HYPERDRIVE_ARUL` |
| R2 binding / bucket | `R2_PAKIZA` / `pakiza` | `R2_ARUL` / `south-indian-wallpapers` |
| cdnBase | `https://cdn.hsrutility.com` | `https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev` |
| apiBase | `https://api.hsrutility.com` | `https://arul-api.twilight-smoke-d495.workers.dev` |
| Rebuild secret | `PAKIZA_CATALOG_BUILD_SECRET` | `ARUL_CATALOG_BUILD_SECRET` |
| Scopes | wallpapers · ringtones · submissions · config | wallpapers · submissions · config |
| Wallpaper keys | `wallpapers/posters/{id}.{ext}` (static) · `wallpapers/full/{id}.mp4` (live) | `wallpapers/<category>/{id}.{ext}` |
| Thumbs | — | `thumbs/<category>/<file-stem>.jpg` |
| Ringtone keys | `ringtones/audio/{id}.{ext}` | — (no ringtones anywhere) |
| Categories | none (tags only) | `category` NOT NULL — browse axis + key partition; free text |

## Routes

Everything is mounted under `/admin` (zone route `api.hsrutility.com/admin*`;
the session cookie is scoped `Path=/admin`):

```
GET/POST /admin/login      POST /admin/logout    (only session-free CMS routes)
GET  /admin  (or /admin/)  combined dashboard (per-app counts + quick links)
POST /admin/{app}/media/upload-url  presigned PUT to that app's bucket + key scheme

/admin/pakiza/{wallpapers,ringtones,submissions,config}
/admin/arul/{wallpapers,submissions,config,transfer}
```

Outside `/admin` (zone route `api.hsrutility.com/payments/webhook*`, no
session auth — PhonePe authenticates via its own callback Authorization
header, verified by the receiving app Worker):

```
POST /payments/webhook     PhonePe S2S dispatcher — merchant id "DKS_…"
                           (payload.merchantOrderId, else
                           payload.merchantSubscriptionId) → ARUL_API;
                           everything else (incl. parse failures) → PAKIZA_API.
                           Forwarded verbatim; downstream response returned as-is.
```

Each app's pages have functional parity with its old per-app CMS:
list / create / edit / publish / unpublish / delete, submission review with
approve (canonical-key copy via S3 CopyObject, HEAD-verified content type) /
reject, and the config editor (support email, min version, `prices`,
`policy_urls`, `feature_flags` + "Rebuild catalog now").

## Publish flow

Every content mutation:

1. writes the row **and** bumps that app's `app_config.content_version` in ONE
   Postgres transaction (crash-safe: no row change without a version bump);
2. fires `POST {apiBase}/internal/build-catalog` with
   `Authorization: Bearer {per-app secret}`.

A failed rebuild **never rolls back** the DB write — the page shows a
*"rebuild failed, retry from App config"* banner and the app Worker's hourly
cron self-heals. Destructive follow-ups (deleting replaced/removed media) run
only **after** a confirmed rebuild, so a stale catalog never points at missing
bytes.

## Category transfer (`/arul/transfer`, Arul only)

Moves wallpapers between categories. Arul keys are category-partitioned, so a
category change is a key change — the flow is **copy-before-update**:

1. **Copy** (R2 binding, get+put): `wallpapers/<src>/<file>` →
   `wallpapers/<dst>/<file>`; thumb `thumbs/<src>/<stem>.jpg` →
   `thumbs/<dst>/<stem>.jpg` *if it exists* (a missing thumb is not an error).
2. **DB txn** (one per batch): `UPDATE wallpapers SET category, full_key` for
   every successfully-copied item + **one** `content_version` bump.
3. **Delete old objects** (media + thumb) only **after** the txn commits.
4. **Trigger** the Arul rebuild.

Partial-failure semantics (per-item results are reported on screen):

- copy failure → that item is excluded from the DB update; the rest move.
  Rows are valid at every instant (the new key exists before any row points at
  it; the old key survives until after commit).
- DB txn failure → nothing moved. Leftover **media** copies self-heal via the
  Arul Worker's hourly canonical sweep; leftover **thumb** copies are deleted
  explicitly here because `thumbs/` is *not* swept.

## wrangler.toml bindings

- `[[hyperdrive]]` `HYPERDRIVE_PAKIZA` (`82a565ff7fb443cc9b761e5fcb5492b3`),
  `HYPERDRIVE_ARUL` (`19dda46cef1c42fc9d3176704feb74dc`)
- `[[r2_buckets]]` `R2_PAKIZA` → `pakiza`, `R2_ARUL` → `south-indian-wallpapers`
- `nodejs_compat`, no crons, account `ba8dd87179e2ffd378a50292ca8e69e0`

## Secrets (`npx wrangler secret put <NAME>`)

| Secret | Purpose |
|---|---|
| `ADMIN_USERNAME` | operator login name |
| `ADMIN_PASSWORD_HASH` | PBKDF2 digest `pbkdf2$<iters>$<saltB64>$<hashB64>` |
| `ADMIN_SESSION_SECRET` | HS256 key for the `hsr_cms` session cookie (≥32 bytes) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ENDPOINT` | ONE account-scoped R2 S3 token — covers both buckets (bucket names come from the registry) |
| `ARUL_CATALOG_BUILD_SECRET` | bearer for Arul's `/internal/build-catalog` |
| `PAKIZA_CATALOG_BUILD_SECRET` | bearer for Pakiza's `/internal/build-catalog` |

Auth: single operator, PBKDF2 password verify + signed HttpOnly `hsr_cms`
cookie (12 h, `Path=/`, Secure off localhost only). Login throttling is an
in-memory per-isolate counter (this Worker has no KV binding; the real cost
gate is the PBKDF2 work factor).

## Commands

```bash
npm install
npx tsc --noEmit        # typecheck
npx vitest run          # tests (all DB/R2/network mocked — never touches prod)
npx wrangler deploy     # deploy (operator-run)
```
