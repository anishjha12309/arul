/**
 * Deep-link routes (PUBLIC — no JWT, these are opened by browsers and crawlers):
 *
 *   GET /.well-known/assetlinks.json — Digital Asset Links, proves this host may
 *                                      open in the app (Android App Links)
 *   GET /w/:id                       — the ONE URL that ships in shares and ad
 *                                      creatives for a specific wallpaper
 *
 * How one URL serves both halves of "open the wallpaper":
 *   · App INSTALLED — Android verified this host against assetlinks.json at
 *     install time, so the OS resolves the https URL straight to the app and
 *     `/w/:id` is never fetched at all. The app reads the id off the intent.
 *   · App NOT installed — nothing intercepts, the browser lands here, and we
 *     redirect to Play carrying `referrer=ref=<code>&w=<id>`. Android replays
 *     that payload to the app on first launch (InstallReferrerService), which is
 *     what makes the wallpaper open AFTER the install completes.
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
 * Wallpaper ids are `uuid` (db/schema/02_content.sql). Validating here keeps
 * arbitrary attacker-supplied text out of the referrer payload we hand Play,
 * and out of the app's own parser on the other side.
 */
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Referral codes are `^[A-Z0-9]{4,16}$` — same shape InstallReferrerService accepts. */
const REF_RE = /^[A-Z0-9]{4,16}$/;

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

// ── GET /w/:id ───────────────────────────────────────────────────────────────

export function handleWallpaperLink(c: Context<{ Bindings: Env }>): Response {
  const id = (c.req.param("id") ?? "").trim();
  const ref = (c.req.query("ref") ?? "").trim().toUpperCase();

  // An id we don't recognise still sends the visitor to the store — a malformed
  // link should cost an install, not 404 at someone who tapped an ad.
  const parts: string[] = [];
  if (REF_RE.test(ref)) parts.push(`ref=${ref}`);
  if (UUID_RE.test(id)) parts.push(`w=${id}`);

  const url = new URL("https://play.google.com/store/apps/details");
  url.searchParams.set("id", PACKAGE_NAME);
  // ONE encodeURIComponent, so Play stores `ref=CODE&w=UUID` and replays it
  // verbatim. URLSearchParams.set does that encoding itself — encoding the
  // string first as well would double-encode it, and the app's
  // Uri.splitQueryString would then see one key called "ref=CODE&w=UUID".
  if (parts.length > 0) url.searchParams.set("referrer", parts.join("&"));

  // 302, not 301: the destination depends on query params and we may later want
  // to change where an uninstalled visitor lands. A cached 301 would outlive that.
  return c.redirect(url.toString(), 302);
}
