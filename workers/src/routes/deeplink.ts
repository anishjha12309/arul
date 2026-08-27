/**
 * Deep-link routes (PUBLIC — no JWT, these are opened by browsers and crawlers):
 *
 *   GET /.well-known/assetlinks.json — Digital Asset Links, proves this host may
 *                                      open in the app (Android App Links)
 *   GET /w/:id                       — the ONE URL that ships in shares and ad
 *                                      creatives for a specific wallpaper
 *   GET /r/:id                       — the same for a ringtone (ad creatives
 *                                      only — the app has no ringtone share)
 *
 * Both content routes take `?ref=<code>` (referral attribution) and
 * `?lang=<code>` (the language the ad was in; the app switches to it).
 *
 * How one URL serves both halves of "open the content":
 *   · App INSTALLED — Android verified this host against assetlinks.json at
 *     install time, so the OS resolves the https URL straight to the app and
 *     these routes are never fetched at all. The app reads the URL off the
 *     intent, query included.
 *   · App NOT installed — nothing intercepts, the browser lands here, and we
 *     redirect to Play carrying `referrer=ref=<code>&w=<id>&lang=<code>` (or
 *     `r=<id>`). Android replays that payload to the app on first launch
 *     (InstallReferrerService), which is what makes the wallpaper/ringtone open
 *     — in the ad's language — AFTER the install completes.
 *
 * The referrer payload is why this is a redirect and not an HTML page: Play only
 * replays a referrer it received on the store URL, so the store URL has to be
 * the thing the browser actually navigates to.
 *
 * Caveat worth knowing before buying ads: an in-app browser (Facebook,
 * Instagram) may load this URL itself rather than handing the OS an intent, in
 * which case the installed user still gets the Play page. The fix is not here —
 * it is putting this URL in the ad platform's deep-link field so the platform
 * does the app hand-off. This route is what that field points at.
 */

import type { Context } from "hono";
import type { Env } from "../env.js";

/** Must match `kPlayPackageId` in the app and `applicationId` in build.gradle.kts. */
const PACKAGE_NAME = "com.hsrutility.arul";

/**
 * The host that ships in shares and ad creatives. Only its ROOT doubles as a
 * "get the app" link — `arul-api.hsrutility.com` shares this Worker and its root
 * must stay a 404 rather than advertise the app to an API caller.
 */
const LINK_HOST = "arul.hsrutility.com";

/**
 * Wallpaper and ringtone ids are `uuid` (db/schema/02_content.sql,
 * 04_ringtones.sql). Validating here keeps arbitrary attacker-supplied text out
 * of the referrer payload we hand Play, and out of the app's own parser on the
 * other side.
 */
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Referral codes are `^[A-Z0-9]{4,16}$` — same shape InstallReferrerService accepts. */
const REF_RE = /^[A-Z0-9]{4,16}$/;

/**
 * The six shipped UI languages — `supportedAppLocales` in the app. Duplicated
 * here by necessity (the Worker has no Dart), so a seventh language is an edit
 * in BOTH places; an unknown code is dropped rather than forwarded, because the
 * app would drop it anyway and the referrer string is better kept clean.
 * Tested against the bare code only — the caller strips case and region tag
 * first, so this must stay in step with the app's `normalizeLang`.
 */
const LANG_RE = /^(en|ta|te|kn|ml|hi)$/;

// ── GET /.well-known/assetlinks.json ─────────────────────────────────────────

export function handleAssetLinks(c: Context<{ Bindings: Env }>): Response {
  const fingerprints = (c.env.ANDROID_CERT_SHA256 ?? "")
    .split(",")
    .map((f) => f.trim().toUpperCase())
    .filter(Boolean);

  if (fingerprints.length === 0) {
    console.error(
      "[assetlinks] ANDROID_CERT_SHA256 is unset — App Links cannot verify",
    );
    // Deliberately not an empty array: Android treats both as a failure, but a
    // 503 with a reason is the one a human debugging "why does my link open the
    // browser" can actually see.
    return c.json(
      { error: "not_configured", message: "ANDROID_CERT_SHA256 is not set" },
      503,
    );
  }

  return c.json(
    [
      {
        relation: ["delegate_permission/common.handle_all_urls"],
        target: {
          namespace: "android_app",
          package_name: PACKAGE_NAME,
          sha256_cert_fingerprints: fingerprints,
        },
      },
    ],
    200,
    {
      // Android's verifier requires application/json and follows NO redirects to
      // reach this file. Hono's c.json already sets the type; the cache header is
      // ours. An hour is short enough that adding a fingerprint takes effect the
      // same day and long enough that the verifier isn't hitting origin.
      "Cache-Control": "public, max-age=3600",
    },
  );
}

// ── GET /w/:id  ·  GET /r/:id ────────────────────────────────────────────────

/** The wallpaper form: `w=<uuid>` in the referrer payload. */
export function handleWallpaperLink(c: Context<{ Bindings: Env }>): Response {
  return redirectToPlay(c, "w");
}

/** The ringtone form: `r=<uuid>` in the referrer payload. */
export function handleRingtoneLink(c: Context<{ Bindings: Env }>): Response {
  return redirectToPlay(c, "r");
}

/**
 * The bare link domain: `arul.hsrutility.com/?lang=hi` is what someone writes
 * when they mean "the app, in Hindi", and a 404 there costs the install it was
 * bought for. Only the not-installed half — the app's filter is a pathPrefix on
 * `/w/` and `/r/`, so an installed phone opens a BROWSER here and reaches Play
 * with an Open button, losing the language. `/w/?lang=hi` is the form that does
 * both halves on every build already out there; keep recommending that one.
 */
export function handleRootLink(c: Context<{ Bindings: Env }>): Response {
  // From the URL, not the Host header: the header is absent in unit contexts and
  // proxy-writable in front of one, and the request URL always carries the host.
  let host = "";
  try {
    host = new URL(c.req.url).hostname.toLowerCase();
  } catch {
    host = "";
  }
  if (host !== LINK_HOST) {
    return c.json(
      {
        error: {
          code: "not_found",
          message: `Route not found: ${c.req.method} ${c.req.path}`,
        },
      },
      404,
    );
  }
  return redirectToPlay(c, "w");
}

/**
 * Send an uninstalled visitor to Play with everything the link carried packed
 * into the store URL's `referrer`, which Android replays to the app after the
 * install. `kind` is the referrer key the app's parser reads back (`w` / `r`).
 */
function redirectToPlay(
  c: Context<{ Bindings: Env }>,
  kind: "w" | "r",
): Response {
  const id = (c.req.param("id") ?? "").trim().toLowerCase();
  const ref = (c.req.query("ref") ?? "").trim().toUpperCase();
  // Region tag stripped exactly as the app's `normalizeLang` does (`hi-IN` → `hi`,
  // `ta_IN` → `ta`). Ad ops paste these by hand, and an ALREADY-INSTALLED user's
  // link honours them — dropping them only here would hand a fresh install a
  // different language than the same URL gives everyone else.
  const norm = (raw: string) => raw.trim().toLowerCase().split(/[-_]/)[0];
  const lang = norm(c.req.query("lang") ?? "");
  // `ilang` = INSTALL language: what an in-app share stamps with the sharer's UI
  // language. It reaches the app only through this referrer, never as a query the
  // App Link parser reads — so a friend's share seeds a FRESH install's language
  // and leaves an existing user's own Settings choice alone (owner's call,
  // 2026-08-27). `lang` is the ad form and always wins, so it takes precedence.
  const ilang = norm(c.req.query("ilang") ?? "");

  // An id we don't recognise still sends the visitor to the store — a malformed
  // link should cost an install, not 404 at someone who tapped an ad. Same for
  // an unknown language: the link is kept, the junk is not.
  const parts: string[] = [];
  if (REF_RE.test(ref)) parts.push(`ref=${ref}`);
  if (UUID_RE.test(id)) parts.push(`${kind}=${id}`);
  const install = LANG_RE.test(lang) ? lang : LANG_RE.test(ilang) ? ilang : "";
  if (install) parts.push(`lang=${install}`);

  const url = new URL("https://play.google.com/store/apps/details");
  url.searchParams.set("id", PACKAGE_NAME);
  // ONE encodeURIComponent, so Play stores `ref=CODE&w=UUID&lang=hi` and
  // replays it verbatim. URLSearchParams.set does that encoding itself —
  // encoding the string first as well would double-encode it, and the app's
  // Uri.splitQueryString would then see one key called "ref=CODE&w=UUID".
  if (parts.length > 0) url.searchParams.set("referrer", parts.join("&"));

  // 302, not 301: the destination depends on query params and we may later want
  // to change where an uninstalled visitor lands. A cached 301 would outlive that.
  return c.redirect(url.toString(), 302);
}
