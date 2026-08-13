/**
 * Unit tests for the public deep-link routes.
 *
 * These two are the only routes a BROWSER ever reaches, and both fail silently
 * in production when they are wrong: a bad assetlinks.json means Android quietly
 * stops verifying the App Link and every shared wallpaper opens a browser tab
 * instead of the app, with nothing logged anywhere. Hence the pinning here.
 */

import { describe, it, expect } from "vitest";
import { makeEnv, makeCtx } from "./_ctx.js";
import { handleAssetLinks, handleWallpaperLink } from "../src/routes/deeplink.js";

const PLAY_SHA =
  "EA:6F:C5:C7:D4:61:9F:FA:65:6A:FB:FF:99:08:69:E9:EE:EE:D3:A4:C1:72:DD:3A:A8:34:DD:9C:1C:1E:60:D3";
const UPLOAD_SHA =
  "0E:29:23:B9:57:58:66:DD:92:9B:37:5F:89:E7:9C:4C:E7:94:85:CC:99:E7:86:E5:BA:0F:A1:FC:A9:C1:35:D9";

const WALLPAPER_ID = "95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f";

/// `params` is what Hono would have matched off `/w/:id`; `query` is derived
/// from the url, so pass the real link the way a browser would send it.
function ctxFor(url: string, env = makeEnv()) {
  const id = new URL(url).pathname.split("/w/")[1];
  return makeCtx({ env, url, ...(id !== undefined ? { params: { id } } : {}) });
}

describe("GET /.well-known/assetlinks.json", () => {
  it("serves a valid Digital Asset Links statement for the app package", async () => {
    const env = makeEnv({ ANDROID_CERT_SHA256: PLAY_SHA });
    const res = handleAssetLinks(ctxFor("https://arul.hsrutility.com/.well-known/assetlinks.json", env));

    expect(res.status).toBe(200);
    // Android's verifier requires application/json specifically.
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = (await res.json()) as Array<Record<string, unknown>>;
    expect(Array.isArray(body)).toBe(true);
    expect(body[0]).toMatchObject({
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: "com.hsrutility.arul",
        sha256_cert_fingerprints: [PLAY_SHA],
      },
    });
  });

  it("serves EVERY comma-separated fingerprint", async () => {
    // Play re-signs the AAB with its own key, so the Play App Signing cert and
    // the upload cert are different certificates. Listing only one of them means
    // verification passes on a locally-built release APK and fails on every
    // install that came from Play — the exact bug that looks like "it works on
    // my phone".
    const env = makeEnv({ ANDROID_CERT_SHA256: `${PLAY_SHA}, ${UPLOAD_SHA}` });
    const res = handleAssetLinks(ctxFor("https://arul.hsrutility.com/.well-known/assetlinks.json", env));

    const body = (await res.json()) as Array<{
      target: { sha256_cert_fingerprints: string[] };
    }>;
    expect(body[0].target.sha256_cert_fingerprints).toEqual([PLAY_SHA, UPLOAD_SHA]);
  });

  it("503s rather than serving an empty statement when unconfigured", async () => {
    // An empty array and a 503 both fail verification, but only one of them is
    // visible to a human wondering why their link opens Chrome.
    const env = makeEnv({ ANDROID_CERT_SHA256: "" });
    const res = handleAssetLinks(ctxFor("https://arul.hsrutility.com/.well-known/assetlinks.json", env));

    expect(res.status).toBe(503);
  });
});

describe("GET /w/:id", () => {
  it("redirects to Play carrying the wallpaper id AND the referral code", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ref=ABCD1234`),
    );

    expect(res.status).toBe(302);
    const location = new URL(res.headers.get("location")!);
    expect(location.origin + location.pathname).toBe(
      "https://play.google.com/store/apps/details",
    );
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    // ONE level of encoding: Play stores this string and replays it verbatim to
    // the app, whose Uri.splitQueryString then reads `ref` and `w` as two keys.
    // Double-encoding would hand the app a single key literally named
    // "ref=ABCD1234&w=<uuid>", and both referral attribution and the deferred
    // deep link would silently stop working.
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&w=${WALLPAPER_ID}`,
    );
  });

  it("carries the id alone when there is no referral code", async () => {
    const res = handleWallpaperLink(ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}`));

    const location = new URL(res.headers.get("location")!);
    expect(location.searchParams.get("referrer")).toBe(`w=${WALLPAPER_ID}`);
  });

  it("still sends a malformed link to the store, without the junk", async () => {
    // A broken link should cost an install, never 404 at someone who tapped an
    // ad — and unvalidated text must not reach the referrer payload.
    const res = handleWallpaperLink(
      ctxFor("https://arul.hsrutility.com/w/not-a-uuid?ref=%3Cscript%3E"),
    );

    expect(res.status).toBe(302);
    const location = new URL(res.headers.get("location")!);
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    expect(location.searchParams.get("referrer")).toBeNull();
  });

  it("normalises a lowercase referral code to the stored uppercase form", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ref=abcd1234`),
    );

    const location = new URL(res.headers.get("location")!);
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&w=${WALLPAPER_ID}`,
    );
  });
});
