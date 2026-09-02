/**
 * Deep-link routes — PUBLIC, no JWT: browsers, Android's verifier and preview crawlers all fetch these.
 *
 * `/w/:id` is the ONE URL that ships in shares and ad creatives; `/r/:id` is the ringtone form, ads only
 * Both take `?ref=<code>` for referral attribution and `?lang=<code>` for the language the ad was in
 * App INSTALLED -> Android resolved this host against assetlinks.json -> the OS opens the app and never fetches here
 * App NOT installed -> the browser lands here -> we send the visitor to Play carrying the whole payload as `referrer`
 * Android replays that payload on first launch -> that is what opens the content, in the ad's language, AFTER install
 * The bounce is a 200 HTML page, NEVER a 302 -> Google Ads refuses an App-campaign deep link whose URL redirects
 * A 302 made every /w/ and /r/ unusable in the deep-link field while the app itself opened them correctly
 * Never reintroduce `<meta http-equiv="refresh">` -> it is the one redirect form an HTML-parsing validator still sees
 * The referrer must ride the store URL the BROWSER navigates to -> Play only replays a referrer it received itself
 * `location.replace()` is a real navigation -> the payload survives it unchanged
 * A preview crawler now renders THIS page instead of Play's listing card -> hence the og: tags and OG_IMAGE
 * Without an og:image every share card degraded from Play's icon card to bare text
 * An in-app browser (Facebook, Instagram) may load this URL itself instead of handing the OS an intent
 * An installed user then still gets the Play page -> the fix is the platform's deep-link field, not this route
 */

import type { Context } from "hono";
import type { Env } from "../env.js";

/** Must match `kPlayPackageId` in the app and `applicationId` in build.gradle.kts. */
const PACKAGE_NAME = "com.hsrutility.arul";

/**
 * The host that ships in shares and ad creatives — only ITS root doubles as a "get the app" link.
 * arul-api.hsrutility.com shares this Worker -> its root must stay a 404, never advertise the app to an API caller
 */
const LINK_HOST = "arul.hsrutility.com";

/**
 * The card a link-preview crawler shows for every share — the app icon, from the CDN.
 *
 * Served from the CDN -> this route still never touches R2 or the DB
 * `brand/` sits OUTSIDE every sweep prefix -> no DB row has to exist to keep these bytes alive
 * Treat it as immutable -> to change the icon, upload a NEW key and point this at it, never overwrite and purge
 * It is square 512x512 -> the card type must be `summary`, since `summary_large_image` wants ~1200x630
 */
const OG_IMAGE = "https://arul-cdn.hsrutility.com/brand/arul-icon.png";
const OG_IMAGE_PX = 512;

/** Ids are `uuid` -> validating HERE keeps attacker text out of the Play referrer payload and the app's parser. */
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Referral codes are `^[A-Z0-9]{4,16}$` — same shape InstallReferrerService accepts. */
const REF_RE = /^[A-Z0-9]{4,16}$/;

/**
 * The six shipped UI languages — `supportedAppLocales` in the app.
 * The Worker has no Dart -> this list is duplicated by necessity -> a seventh language is an edit in BOTH places
 * An unknown code is DROPPED, not forwarded -> the app would drop it anyway and the referrer stays clean
 * Tested against the bare code only -> the caller strips case and region first -> keep in step with `normalizeLang`
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
    // Deliberately not an empty array -> Android treats both as failure -> only a 503 with a reason is visible to a human
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
      // Android's verifier requires application/json and follows NO redirects to reach this file
      // An hour is short enough that adding a fingerprint takes effect the same day, long enough to spare origin
      "Cache-Control": "public, max-age=3600",
    },
  );
}

// ── GET /w/:id  ·  GET /r/:id ────────────────────────────────────────────────

/** The wallpaper form: `w=<uuid>` in the referrer payload. */
export function handleWallpaperLink(c: Context<{ Bindings: Env }>): Response {
  return bounceToPlay(c, "w");
}

/** The ringtone form: `r=<uuid>` in the referrer payload. */
export function handleRingtoneLink(c: Context<{ Bindings: Env }>): Response {
  return bounceToPlay(c, "r");
}

/**
 * The bare link domain — `arul.hsrutility.com/?lang=hi` is what someone writes for "the app, in Hindi".
 * A 404 there costs the install it was bought for -> serve the bounce page
 * It covers only the NOT-installed half -> the app's filter is a pathPrefix on `/w/` and `/r/`
 * So an installed phone opens a BROWSER here, reaches Play with an Open button, and loses the language
 * `/w/?lang=hi` does both halves on every build already in the field -> keep recommending that form to ad ops
 */
export function handleRootLink(c: Context<{ Bindings: Env }>): Response {
  // From the URL, never the Host header -> that header is absent in unit contexts and proxy-writable in front of one
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
  return bounceToPlay(c, "w");
}

/**
 * The store URL for an uninstalled visitor, with everything the link carried packed into `referrer`.
 * That payload is what Android replays to the app after install -> `kind` is the key the app's parser reads back
 */
function playStoreUrl(
  c: Context<{ Bindings: Env }>,
  kind: "w" | "r",
): string {
  const id = (c.req.param("id") ?? "").trim().toLowerCase();
  const ref = (c.req.query("ref") ?? "").trim().toUpperCase();
  // Strip the region tag exactly as the app's `normalizeLang` does -> `hi-IN` becomes `hi`
  // Ad ops paste these by hand and an ALREADY-INSTALLED user's link honours them
  // Dropping them only here would hand a fresh install a different language than the same URL gives everyone else
  const norm = (raw: string) => raw.trim().toLowerCase().split(/[-_]/)[0];
  const lang = norm(c.req.query("lang") ?? "");
  // `ilang` = INSTALL language -> an in-app share stamps it with the SHARER's UI language
  // It reaches the app only through this referrer, never as a query the App Link parser reads
  // So a friend's share seeds a FRESH install's language and leaves an existing user's Settings choice alone
  // `lang` is the ad form and always wins -> it takes precedence over `ilang`
  const ilang = norm(c.req.query("ilang") ?? "");

  // An unrecognised id still sends the visitor to the store -> a malformed link must not 404 at someone who tapped an ad
  // Same for an unknown language -> the link is kept, the junk is dropped
  const parts: string[] = [];
  if (REF_RE.test(ref)) parts.push(`ref=${ref}`);
  if (UUID_RE.test(id)) parts.push(`${kind}=${id}`);
  // An id-less `/r/` names the RINGTONES section, and the PATH does not survive the trip through Play
  // The app only ever sees this referrer string -> `/w/?lang=ta` and `/r/?lang=ta` would arrive byte-identical
  // A fresh install would then land on the feed -> `screen=` is what distinguishes them
  // The app's referrer parser ALREADY reads that key -> this reaches builds older than the id-less path
  else if (kind === "r") parts.push("screen=ringtones");
  const install = LANG_RE.test(lang) ? lang : LANG_RE.test(ilang) ? ilang : "";
  if (install) parts.push(`lang=${install}`);

  const url = new URL("https://play.google.com/store/apps/details");
  url.searchParams.set("id", PACKAGE_NAME);
  // Exactly ONE encodeURIComponent -> Play stores the payload and replays it verbatim
  // URLSearchParams.set encodes on its own -> encoding the string first as well double-encodes it
  // The app's Uri.splitQueryString would then see one key literally named "ref=CODE&w=UUID"
  if (parts.length > 0) url.searchParams.set("referrer", parts.join("&"));

  return url.toString();
}

/** Escape for an HTML attribute or text node. */
function esc(raw: string): string {
  return raw
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * The bounce page. Every value on it is validated, so no visitor-supplied text reaches the markup.
 * The escaping is belt-and-braces for the day someone adds an unvalidated key -> keep it
 * The `<a>` is the real fallback for a JS-off browser AND what a preview crawler renders
 * No `<meta http-equiv="refresh">` -> see the file header -> a validator still reads that as a redirect
 */
function bounceToPlay(
  c: Context<{ Bindings: Env }>,
  kind: "w" | "r",
): Response {
  const store = playStoreUrl(c, kind);
  const here = c.req.url;
  const title = "Arul — Devotional Wallpapers & Ringtones";
  const blurb =
    "South Indian devotional wallpapers and ringtones. Opening the Arul app…";

  const html = `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<meta property="og:type" content="website">
<meta property="og:site_name" content="Arul">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(blurb)}">
<meta property="og:url" content="${esc(here)}">
<meta property="og:image" content="${esc(OG_IMAGE)}">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="${OG_IMAGE_PX}">
<meta property="og:image:height" content="${OG_IMAGE_PX}">
<meta property="og:image:alt" content="Arul">
<meta name="twitter:card" content="summary">
<style>
  :root { color-scheme: light dark }
  body { margin:0; min-height:100vh; display:flex; align-items:center;
         justify-content:center; text-align:center; padding:24px;
         font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
         background:#100d08; color:#f4ecd8 }
  h1 { margin:0 0 4px; font-size:28px; letter-spacing:.02em; color:#e8b64c }
  p  { margin:0 0 24px; opacity:.75 }
  a  { display:inline-block; padding:12px 24px; border-radius:999px;
       background:#e8b64c; color:#100d08; font-weight:600;
       text-decoration:none }
</style>
<main>
  <h1>Arul</h1>
  <p>${esc(blurb)}</p>
  <a href="${esc(store)}">Continue to Google Play</a>
</main>
<script>location.replace(${JSON.stringify(store).replace(/</g, "\\u003C")})</script>
`;

  return new Response(html, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      // The destination derives from the query, which is already part of the cache key
      // But this page is the campaign's front door -> a change to it must be live everywhere the moment it deploys
      "cache-control": "no-store",
    },
  });
}
