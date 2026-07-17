# HSR unified CMS — live production smoke-test plan

**Target:** `https://api.hsrutility.com/admin` (deployed `hsr-cms` Worker, manages **Pakiza** + **Arul**).
**Nature:** hit the REAL deployed endpoints and observe behavior — this is integration/smoke, not unit tests.
**Orchestrator:** Opus. **Executors:** 4 Sonnet agents, one section each (A/B/C/D). Report findings back compactly.

---

## 0. RULES OF ENGAGEMENT (read first — violating these can damage a live app)

1. **Pakiza is a SHIPPED app with real users. NEVER mutate Pakiza content.** No create/update/publish/unpublish/delete/transfer/approve/reject on Pakiza wallpapers, ringtones, submissions, or config. Pakiza is **READ + rebuild-only** (a rebuild regenerates the catalog from the *current* DB — it changes nothing).
2. **The ONLY writes allowed anywhere are Section C's single disposable draft on ARUL, and idempotent rebuilds.** Everything else is GET or a *deliberately-invalid* POST that must be **rejected before any DB write**.
3. **Login throttle = 10 failures / 15 min, counted PER CLIENT-IP.** All agents share one egress IP. So: **use the EXACT correct password for every real login; never guess.** Only Agent A may do wrong-password tests, capped at **2**, and must stop the instant it has its evidence. If any login returns a "locked/too many attempts" response, STOP all login attempts and report.
4. **Credentials** are supplied in your dispatch prompt (username + password). They are NOT written in this file. Do not echo the password into any file you create.
5. **Never send a well-formed / signed payment callback** to `/payments/webhook`. Only an empty/`{}` body to confirm routing.
6. **Compact reporting only.** Return a markdown table `| ID | endpoint | expected | actual | PASS/FAIL |`, then an `ANOMALIES` list, then (Section C only) a `CLEANUP CONFIRMED` line. Do NOT paste full HTML — quote ≤120-char snippets as evidence. Prefer `curl` (cheap) over browser automation; use the Playwright MCP only where a behavior is client-side JS (search/filter/grid-toggle) and take ≤2 screenshots total.
7. Expectations below are framed as **intent + "record actual"** — if a status differs harmlessly (e.g. 400 vs 422), record the actual code and mark PASS if the *intent* held (rejected / accepted / routed). Flag anything genuinely wrong under ANOMALIES.
8. A concurrent agent (Section C) may briefly create a row titled `ZZ_SMOKE_TEST_DELETE_ME` on Arul. Ignore it in inventory assertions; it is cleaned up.

**Login recipe (curl, reuse the cookie jar):**
```
curl -s -c cj.txt -b cj.txt https://api.hsrutility.com/admin/login          # prime
curl -s -c cj.txt -b cj.txt -X POST https://api.hsrutility.com/admin/login \
     --data-urlencode "username=<USER>" --data-urlencode "password=<PASS>" -i
# then reuse -b cj.txt -c cj.txt on every subsequent request
```
Login field names may be `username`/`password` — if the form uses different names, read them from the `GET /admin/login` HTML first.

---

## SECTION A — Auth, session, routing guards, dashboard, webhook dispatcher
*Model: Sonnet. Needs the real login for the positive path. Read-only + 2 bounded wrong-logins.*

| ID | Scenario | Expected intent |
|----|----------|-----------------|
| A1 | `GET /admin/login` | 200; HTML has a password field + a POST form. Record the actual field names. |
| A2 | `GET /admin` no cookie | 302 → `/admin/login`. |
| A3 | `GET /admin/pakiza/wallpapers` no cookie | redirect to login (guard covers sub-routes). |
| A4 | `GET /admin/arul/wallpapers` no cookie | redirect to login. |
| A5 | `GET /admin` no cookie **with header `HX-Request: true`** | **401** + response header `HX-Redirect: /admin/login` (NOT a 302). |
| A6 | `POST /admin/pakiza/wallpapers/00000000-0000-0000-0000-000000000000/delete` **no cookie** | blocked by guard (redirect/401); NO mutation. Confirms mutation routes are guarded. |
| A7 | `POST /admin/login` **WRONG** password ×2 (STOP at 2) | login rejected (re-renders login / 401). Note the failure UX. **Do not exceed 2.** |
| A8 | `POST /admin/login` correct password | success (302 or 200); `Set-Cookie: hsr_cms=…` present with `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/admin`. Record the flags. |
| A9 | `GET /admin` WITH cookie | 200 dashboard; shows BOTH apps (Pakiza + Arul), a `v<n>` version chip each, published/total wallpaper counts, pending-submission counts, and Arul's "Published by category" card. |
| A10 | Dashboard DB health | counts are real integers, NOT a "Could not reach the … database" banner. A banner = Hyperdrive/Neon binding broken for that app → FAIL. Record both apps' numbers. |
| A11 | `POST /admin/logout` with cookie | clears `hsr_cms` (Set-Cookie expiring it); a follow-up `GET /admin` → 302. |
| A12 | `GET /admin` with a **tampered** cookie (`hsr_cms=garbage.jwt.value`) | 302 → login (signature verify fails). |
| A13 | `GET /payments/webhook` | 404 (POST-only route). |
| A14 | `POST /payments/webhook` body `{}` (Content-Type application/json) | routed (NOT 404) and the CMS worker does not 500. Record the status; **do not** send a signed/real callback. |
| A15 | `GET /admin/arul/ringtones` WITH cookie | **200** — FLIPPED 2026-07-17: Arul ringtones launched (`makeArulRingtonesApp`). List page renders; with zero rows the guidance empty-state card ("No ringtones yet…", batch CTA) must render, NOT a blank grid or 500. (Was 404 pre-launch.) |
| A16 | `GET /admin/nonexistent-xyz` WITH cookie | 404 (or graceful). Record. |
| A17 | `GET /admin/` (trailing slash) WITH cookie | dashboard renders (strict:false). |

---

## SECTION B — Wallpapers READ matrix + media presign + validation (BOTH apps, NO successful writes)
*Model: Sonnet. Needs login. curl for all API/validation; ONE short Playwright session for client-JS behaviors.*

**Read/render (curl):**
| ID | Scenario | Expected intent |
|----|----------|-----------------|
| B1 | `GET /admin/pakiza/wallpapers` | 200; table rows have an 8-char ID code, an "Added" date, and a thumbnail cell; a hidden `.keysearch` span per row containing the FULL uuid + FULL R2 key (so search can match). |
| B2 | `GET /admin/arul/wallpapers` | 200; same, plus a category value per row. |
| B3 | `GET /admin/pakiza/wallpapers/new` | 200 upload form (multi-file input present). |
| B4 | `GET /admin/arul/wallpapers/new` | 200 upload form; category `<select>` present. |
| B5 | `GET /admin/{app}/wallpapers/:id/edit` for a REAL id you read from B1/B2 | 200 edit form pre-filled. **Do not submit.** |
| B6 | `GET /admin/arul/wallpapers/<bogus-uuid>/edit` | 404 / graceful not-found. |
| B7 | Grid markup present | list HTML contains BOTH a table (`tr[data-id]`) and grid cards (`[data-grid-id]`) + a view-toggle control (syncGrid mirrors them). |

**Presign happy paths (POST `/admin/{app}/media/upload-url`, JSON body):**
| ID | Body | Expected |
|----|------|----------|
| B8 | Arul `{kind:"wallpaper",contentType:"image/jpeg",size:200000,category:"amman"}` | 200 `{id,key,uploadUrl}`; key starts `wallpapers/amman/`; **no** thumbKey (image). |
| B9 | Arul `{kind:"wallpaper",contentType:"video/mp4",size:2000000,category:"murugan"}` | 200 `{id,key,uploadUrl,thumbKey,thumbUploadUrl}`; `thumbKey` = `thumbs/murugan/<stem>.jpg` — **TOP-LEVEL `thumbs/`, NOT under `wallpapers/`.** |
| B10 | Pakiza `{kind:"wallpaper",contentType:"video/mp4",size:2000000}` | 200 with `thumbKey` = `thumbs/full/<stem>.jpg` (top-level). |
| B11 | **Pakiza static future-proofing** `{kind:"wallpaper",contentType:"image/jpeg",size:200000}` | 200 `{id,key,uploadUrl}`; key under `wallpapers/posters/`; **no** thumbKey (Pakiza image derives no thumb — this is the "if Pakiza takes static images nothing breaks" check). |

**Presign validation negatives (each → 4xx JSON `{error:{code,…}}`, NO object created):**
| ID | Body | Expected code (intent) |
|----|------|------------------------|
| B12 | non-JSON body (`--data 'notjson'`) | 400 invalid_body |
| B13 | `{contentType:"image/jpeg"}` (missing kind) | 400 missing_field |
| B14 | `{kind:"wallpaper"}` (missing contentType) | 400 missing_field |
| B15 | Arul `{kind:"wallpaper",contentType:"image/jpeg"}` (missing category) | 400 missing_field (category required) |
| B16 | `{kind:"wallpaper",contentType:"image/svg+xml",category:"amman"}` | 400 bad_type |
| B17 | `{kind:"wallpaper",contentType:"image/jpeg",size:999999999,category:"amman"}` | 400 too_large |
| B18 | `{kind:"bogus",contentType:"image/jpeg",category:"amman"}` | 400 bad_target |
| B19 | inject `{…,"key":"../evil","id":"x"}` | server IGNORES caller key/id; returns its own server-generated key (no path traversal possible). |

**Create/bulk validation negatives (must reject PRE-write — verify list count unchanged before/after):**
| ID | Scenario | Expected |
|----|----------|----------|
| B20 | `POST /admin/arul/wallpapers` with `items_json` whose key contains `..` | rejected; no row created; no rebuild. |
| B21 | same with a key >300 chars | rejected. |
| B22 | same with mime not image/* or video/mp4 | rejected. |
| B23 | `items_json` = malformed JSON / empty array | 400 or no-op; no row. |
| B24 | `POST /admin/arul/wallpapers/bulk` with malformed ids (non-uuid) or missing `ids` | rejected; no change. |
| B25 | `POST /admin/arul/wallpapers/bulk` unknown `action` | rejected; no change. |

**Client-side JS (ONE Playwright session on live Arul wallpapers; ≤2 screenshots):**
| ID | Scenario | Expected |
|----|----------|----------|
| B26 | Type a known ID-prefix / R2-key fragment into search | only matching row(s) remain visible (matches against the hidden keysearch span). |
| B27 | Click a category chip (Arul) then a status chip | list filters live; static+live interleave within a category (no static-vs-live tab). |
| B28 | Toggle table→grid, reload page | view persists (localStorage). |

---

## SECTION C — Controlled WRITE lifecycle (ARUL ONLY) + config/rebuild + transfer render
*Model: Sonnet. Needs login. This is the ONLY agent that writes to prod. Strictly Arul. Guaranteed cleanup.*

**C1 — End-to-end lifecycle (proves presign → PUT → create → edit → publish → delete → version-bump → rebuild → R2 cleanup in prod).** All on **Arul**. Row title MUST be `ZZ_SMOKE_TEST_DELETE_ME`.
1. Presign junk image: `POST /admin/arul/media/upload-url {kind:"wallpaper",contentType:"image/jpeg",size:1000,category:"temples"}` → capture `{id,key,uploadUrl}`.
2. `PUT` a tiny valid JPEG (a 1×1 baseline JPEG is fine) to `uploadUrl` with `Content-Type: image/jpeg` → 2xx.
3. Create a **DRAFT** (unpublished) row via `POST /admin/arul/wallpapers` referencing that key, title `ZZ_SMOKE_TEST_DELETE_ME`, category `temples`. Record success + note the catalog version before/after (should bump by 1).
4. `GET /admin/arul/wallpapers` → the row appears; capture its real `:id`.
5. `GET /admin/arul/wallpapers/:id/edit` → 200 pre-filled.
6. `POST /admin/arul/wallpapers/:id` update → rename to `ZZ_SMOKE_TEST_2` → success; verify the change on reload.
7. `POST /admin/arul/wallpapers/:id/publish` → `is_published` becomes true; version bumps again. Read the row/list to confirm.
8. Toggle back to draft (call the publish route again if it toggles, else the unpublish path) so it never lingers published. Confirm state = draft.
9. `POST /admin/arul/wallpapers/:id/delete` → row gone; version bumps; the R2 object is deleted.
10. **Verify cleanup:** `GET` list → row absent; `curl -I` the CDN URL for that key → 404/not-found (object gone).
11. **Mandatory:** if ANY step above throws, still delete the row and the R2 object before finishing. End state MUST be: no `ZZ_SMOKE_TEST*` row, no leftover R2 object.

**C2 — Config + rebuild (idempotent; safe):**
| ID | Scenario | Expected |
|----|----------|----------|
| C2a | `GET /admin/arul/config` | 200 renders (content_version, rebuild control). |
| C2b | `GET /admin/pakiza/config` | 200 renders. **READ ONLY — do not POST any config change to Pakiza.** |
| C2c | `POST /admin/arul/config/rebuild` | success banner → proves the `ARUL_API` service binding + build-catalog work. |
| C2d | `POST /admin/pakiza/config/rebuild` | success banner → proves `PAKIZA_API` service binding + `PAKIZA_CATALOG_BUILD_SECRET` against PROD (this was never verified before — a **401** here means the secret differs from prod; record it, it's safe either way, no content changes). |

*Do NOT POST `/admin/arul/config` or `/admin/pakiza/config` (real settings writes). Rebuild only.*

**C3 — Transfer (Arul only, render + validation; NO real transfer):**
| ID | Scenario | Expected |
|----|----------|----------|
| C3a | `GET /admin/arul/transfer` | 200 renders (source + target category selectors). |
| C3b | `POST /admin/arul/transfer` with empty/bogus payload (no ids, or an invalid target category) | rejected; no media moved, no version bump. **Do not run a real transfer.** |

Finish with a `CLEANUP CONFIRMED:` line stating the test row and R2 object are gone.

---

## SECTION D — Pakiza specifics, ringtones, submissions (READ), CDN/thumb integrity, isolation
*Model: Sonnet. Needs login. Read + validation only. NO approve/reject, NO ringtone writes.*

**D1 — Pakiza ringtones (read + presign validation):**
| ID | Scenario | Expected |
|----|----------|----------|
| D1a | `GET /admin/pakiza/ringtones` | 200 list renders. |
| D1b | `GET /admin/pakiza/ringtones/new` | 200 form. |
| D1c | `GET /admin/pakiza/ringtones/:id/edit` (real id) | 200 pre-filled. Do not submit. |
| D1d | Ringtone presign `POST /admin/pakiza/media/upload-url {kind:"ringtone",contentType:"audio/mpeg",size:1000000}` | 200; key under `ringtones/audio/`. |
| D1e | Same ringtone presign on **Arul** *without* a category | 400 missing_field — FLIPPED 2026-07-17: Arul now HAS ringtones, but category is required (key partition). (Was 400 bad_target pre-launch.) |
| D1f | Arul ringtone presign `{kind:"ringtone",contentType:"audio/mpeg",size:1000000,category:"amman"}` | 200; key under `ringtones/amman/` ending `.mp3`. |
| D1g | Arul cover presign `{kind:"ringtone_cover",contentType:"image/jpeg",size:100000,category:"amman"}` | 200; key under `ringtones/covers/amman/` ending `.jpg`. |
| D1h | Arul cover presign with `contentType:"image/png"` | 400 bad_target (covers are JPEG-only). |

**D2 — Pakiza wallpaper thumbnails (issue-#2 fix, verify LIVE):**
| ID | Scenario | Expected |
|----|----------|----------|
| D2a | `GET /admin/pakiza/wallpapers`; extract several LIVE (video) rows' thumbnail `<img src>` | each is a CDN `…/thumbs/full/<stem>.jpg` URL. |
| D2b | `curl -I` those thumb URLs | 200 + `content-type: image/jpeg` (proves the 111-row backfill serves). |
| D2c | STATIC (poster) rows' `<img src>` | the poster image itself (`wallpapers/posters/…`), NOT a `thumbs/` URL — static path intact (future-proofing). |
| D2d | Count live rows still showing the ▶ placeholder (no thumb) | report the number (expect ~0). |

**D3 — Arul thumbnails:**
| ID | Scenario | Expected |
|----|----------|----------|
| D3a | `GET /admin/arul/wallpapers`; live rows' thumb src | CDN `…/thumbs/<category>/<stem>.jpg`; `curl -I` → 200 image/jpeg. |
| D3b | Static rows' src | their own image; report placeholder count. |

**D4 — Submissions (READ ONLY — never approve/reject real user submissions):**
| ID | Scenario | Expected |
|----|----------|----------|
| D4a | `GET /admin/pakiza/submissions` | 200 list (states render). |
| D4b | `GET /admin/arul/submissions` | 200 list. |
| D4c | `GET /admin/{app}/submissions/:id` (a real id if any exists) | 200 detail (media preview + approve/reject buttons visible). **Do NOT POST approve/reject.** |
| D4d | If an app has zero submissions | empty-state renders (not a 500). |

**D4b2 — ARUL ringtones page (NEW 2026-07-17 — read + validation only, NO ringtone writes unless Section C adopts the lifecycle):**
| ID | Scenario | Expected |
|----|----------|----------|
| D4r1 | `GET /admin/arul/ringtones` | 200. Zero rows → guidance empty-state ("No ringtones yet", audio ≤15MB MP3 / cover 512×512 JPG copy, batch-upload CTA). With rows → table has Title/Category/Duration/Status/ID/Added columns, a hidden `.keysearch` span per row carrying full uuid + audio_key + cover_key, a category filter select listing all six known categories, and a `data-bulk-bar` pill form with publish/unpublish/category-move/delete controls. |
| D4r2 | Grid markup | list HTML (when rows exist) contains `.rtcard` cards with a square cover `<img>` (or ♪ placeholder when cover_key is null) and an inline `<audio controls preload="none">` whose src is the CDN audio URL. A published row without a cover shows the "no cover" warn badge. |
| D4r3 | `GET /admin/arul/ringtones/new` | 200; form has BOTH file inputs (audio accept mp3/m4a/aac + cover accept jpeg), category datalist, hidden `duration_ms`/`bytes_audio` fields, and `data-presign="/admin/arul/media/upload-url"`. |
| D4r4 | `POST /admin/arul/ringtones` with audio key but **no** `key_cover` | rejected pre-write ("Cover image upload did not complete…"); list count unchanged; no version bump. |
| D4r5 | `POST /admin/arul/ringtones` `items_json` with a `..` key / non-audio mime / missing cover_key | each rejected pre-write with its specific message. |
| D4r6 | `POST /admin/arul/ringtones/bulk` `bulk_action=category` without `bulk_category` | rejected ("Choose a target category"); no change. |
| D4r7 | `GET /admin/pakiza/ringtones` after all of the above | byte-wise UNCHANGED behavior vs D1a — no category filter, no grid cards, no cover column (Arul launch must not leak into Pakiza's page). |

**D5 — Cross-app isolation & edge:**
| ID | Scenario | Expected |
|----|----------|----------|
| D5a | Compare Arul vs Pakiza CDN bases in rendered URLs | Pakiza uses `cdn.hsrutility.com`; Arul uses its own r2.dev/cdn base — no cross-bleed. |
| D5b | `GET /admin/pakiza/wallpapers/<an-Arul-id>/edit` | 404 (Arul id not found in Pakiza's DB — structural isolation). |
| D5c | Tamil / long-unicode titles in any list | render without breaking layout (observational). |

---

## Reporting back (every agent)
1. The results table (all IDs, PASS/FAIL/actual).
2. `ANOMALIES:` bullet list — anything unexpected, with the ≤120-char evidence snippet.
3. Section C only: `CLEANUP CONFIRMED: <yes/no + what remains if no>`.
4. One-line `VERDICT:` healthy / degraded / broken for your section.
