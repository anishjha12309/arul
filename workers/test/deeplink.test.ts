/**
 * The public deep-link routes — the only ones a BROWSER ever reaches.
 *
 * Both fail SILENTLY in production when wrong -> a bad assetlinks.json stops Android verifying the App Link
 * Every shared wallpaper then opens a browser tab instead of the app, with nothing logged anywhere
 * That invisibility is why these are pinned here rather than left to on-device checks
 */

import { describe, it, expect } from "vitest";
import { makeEnv, makeCtx } from "./_ctx.js";
import {
  handleAssetLinks,
  handleWallpaperLink,
  handleRingtoneLink,
  handleRootLink,
} from "../src/routes/deeplink.js";

const PLAY_SHA =
  "EA:6F:C5:C7:D4:61:9F:FA:65:6A:FB:FF:99:08:69:E9:EE:EE:D3:A4:C1:72:DD:3A:A8:34:DD:9C:1C:1E:60:D3";
const UPLOAD_SHA =
  "0E:29:23:B9:57:58:66:DD:92:9B:37:5F:89:E7:9C:4C:E7:94:85:CC:99:E7:86:E5:BA:0F:A1:FC:A9:C1:35:D9";

const WALLPAPER_ID = "95b5276e-1c2d-4f3a-9b8e-7d6c5a4b3e2f";
const RINGTONE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-9e8f7a6b5c4d";

/// `params` is what Hono would have matched off `/w/:id`; `query` derives from the URL
/// So pass the REAL link exactly as a browser would send it -> a synthesised query tests the wrong thing
function ctxFor(url: string, env = makeEnv()) {
  const match = new URL(url).pathname.match(/^\/[wr]\/(.+)$/);
  const id = match?.[1];
  return makeCtx({ env, url, ...(id !== undefined ? { params: { id } } : {}) });
}

/**
 * The store URL the bounce page navigates to.
 * These routes answer 200 with HTML, never 302 -> Google Ads rejects a deep link whose URL redirects
 * So there is no `Location` header to read -> the destination lives in the page's own `location.replace()`
 * Reading it from there is deliberate -> that is the line real visitors execute
 */
async function dest(res: Response): Promise<URL> {
  expect(res.status).toBe(200);
  expect(res.headers.get("content-type")).toContain("text/html");
  const html = await res.text();
  // A redirect the page performs ITSELF is the whole point -> assert we never grow one a validator can see
  expect(html).not.toMatch(/http-equiv=["']?refresh/i);
  const match = html.match(/location\.replace\((".*?")\)/);
  expect(match, "bounce page has no location.replace()").not.toBeNull();
  const url = new URL(JSON.parse(match![1]) as string);
  // The visible fallback must AGREE with it -> otherwise a JS-off visitor lands somewhere the campaign did not buy
  expect(html).toContain(`href="${url.toString().replace(/&/g, "&amp;")}"`);
  return url;
}

describe("GET /.well-known/assetlinks.json", () => {
  it("serves a valid Digital Asset Links statement for the app package", async () => {
    const env = makeEnv({ ANDROID_CERT_SHA256: PLAY_SHA });
    const res = handleAssetLinks(ctxFor("https://arul.hsrutility.com/.well-known/assetlinks.json", env));

    expect(res.status).toBe(200);
    // Android's verifier requires application/json SPECIFICALLY -> any other type fails verification silently
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
    // Play re-signs the AAB with its own key -> the App Signing cert and the upload cert are DIFFERENT certificates
    // Listing only one passes on a locally-built release APK and fails on every install that came from Play
    // That is the exact bug that looks like "it works on my phone" -> assert both are served
    const env = makeEnv({ ANDROID_CERT_SHA256: `${PLAY_SHA}, ${UPLOAD_SHA}` });
    const res = handleAssetLinks(ctxFor("https://arul.hsrutility.com/.well-known/assetlinks.json", env));

    const body = (await res.json()) as Array<{
      target: { sha256_cert_fingerprints: string[] };
    }>;
    expect(body[0].target.sha256_cert_fingerprints).toEqual([PLAY_SHA, UPLOAD_SHA]);
  });

  it("503s rather than serving an empty statement when unconfigured", async () => {
    // An empty array and a 503 both fail verification -> only the 503 is visible to a human debugging it
    const env = makeEnv({ ANDROID_CERT_SHA256: "" });
    const res = handleAssetLinks(ctxFor("https://arul.hsrutility.com/.well-known/assetlinks.json", env));

    expect(res.status).toBe(503);
  });
});

// The contract that cost a campaign: Google Ads FETCHES the deep-link URL and rejects one that redirects
// While these routes 302'd, every /w/ and /r/ link was refused in the campaign's deep-link field
// The app itself was verified and opening them correctly -> the error pointed at nothing a build could fix
describe("no HTTP redirect on any deep-link route", () => {
  it.each([
    ["wallpaper", () => handleWallpaperLink(ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?lang=ta`))],
    ["ringtone", () => handleRingtoneLink(ctxFor(`https://arul.hsrutility.com/r/${RINGTONE_ID}?lang=ta`))],
    ["ringtone tab", () => handleRingtoneLink(ctxFor("https://arul.hsrutility.com/r/?lang=ta"))],
    ["language-only", () => handleWallpaperLink(ctxFor("https://arul.hsrutility.com/w/?lang=hi"))],
    ["root", () => handleRootLink(makeCtx({ env: makeEnv(), url: "https://arul.hsrutility.com/?lang=hi" }))],
  ])("%s links answer 200 with no Location header", async (_name, call) => {
    const res = call();

    expect(res.status).toBe(200);
    expect(res.headers.get("location")).toBeNull();
    // …and still reach Play -> the fix cannot have been "stop sending anyone anywhere"
    expect((await dest(res)).origin).toBe("https://play.google.com");
  });
});

// A link-preview crawler renders THIS page now that it no longer follows a 302 to Play's listing card
// WhatsApp is the first hop of every share -> a share with no og:image is a share that lost its picture
describe("link-preview card", () => {
  it("carries an og:image on a CDN prefix no sweep can reclaim", async () => {
    const res = handleWallpaperLink(ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}`));
    const html = await res.text();

    expect(html).toContain(
      '<meta property="og:image" content="https://arul-cdn.hsrutility.com/brand/arul-icon.png">',
    );
    // `brand/` sits outside CANONICAL_PREFIXES and SUBMISSION_PREFIX -> the bytes survive with no DB row
    // Moving it under wallpapers/ or ringtones/ would have the sweep delete the icon within the grace window
    expect(html).not.toMatch(/og:image"[^>]*(wallpapers|ringtones|thumbs|user)\//);
    // The art is square -> summary_large_image would letterbox it -> the card type must stay `summary`
    expect(html).toContain('<meta name="twitter:card" content="summary">');
    expect(html).toContain('<meta property="og:title"');
    expect(html).toContain('<meta property="og:url"');
  });
});

describe("GET /w/:id", () => {
  it("sends the visitor to Play carrying the wallpaper id AND the referral code", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ref=ABCD1234`),
    );

    expect(res.status).toBe(200);
    const location = await dest(res);
    expect(location.origin + location.pathname).toBe(
      "https://play.google.com/store/apps/details",
    );
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    // Exactly ONE level of encoding -> Play stores this string and replays it VERBATIM to the app
    // The app's Uri.splitQueryString then reads `ref` and `w` as two keys
    // Double-encoding hands it a single key literally named "ref=…&w=…" -> attribution and the deferred link both die
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&w=${WALLPAPER_ID}`,
    );
  });

  it("carries the id alone when there is no referral code", async () => {
    const res = handleWallpaperLink(ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}`));

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(`w=${WALLPAPER_ID}`);
  });

  it("still sends a malformed link to the store, without the junk", async () => {
    // A broken link must never 404 at someone who tapped an ad -> and unvalidated text must not reach the payload
    const res = handleWallpaperLink(
      ctxFor("https://arul.hsrutility.com/w/not-a-uuid?ref=%3Cscript%3E"),
    );

    expect(res.status).toBe(200);
    const location = await dest(res);
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    expect(location.searchParams.get("referrer")).toBeNull();
  });

  it("normalises a lowercase referral code to the stored uppercase form", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ref=abcd1234`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&w=${WALLPAPER_ID}`,
    );
  });

  it("carries the ad's language through to the referrer", async () => {
    // The ad's language is what the app switches to after install -> it must survive the Play round-trip like the id
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ref=ABCD1234&lang=hi`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&w=${WALLPAPER_ID}&lang=hi`,
    );
  });

  it("drops a language outside the six shipped codes, keeps the rest", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?lang=fr`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(`w=${WALLPAPER_ID}`);
  });

  it("lower-cases the language and the id", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID.toUpperCase()}?lang=TA`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(`w=${WALLPAPER_ID}&lang=ta`);
  });

  // Ad ops paste `hi-IN` as readily as `hi`, and an installed user's link honours it via normalizeLang
  // Dropping it only on the NOT-installed path handed a fresh install the device language
  // Everyone else got Hindi from the same URL -> the two paths must strip the region tag identically
  it.each([
    ["hi-IN", "hi"],
    ["ta_IN", "ta"],
    ["TA-in", "ta"],
  ])("strips the region tag off %s like the app does", async (raw, want) => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?lang=${raw}`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `w=${WALLPAPER_ID}&lang=${want}`,
    );
  });

  it("still drops a region-tagged language we do not ship", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?lang=pt-BR`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(`w=${WALLPAPER_ID}`);
  });
});

describe("GET /r/:id", () => {
  it("redirects to Play carrying the ringtone id under the r= key", async () => {
    // `r=`, never `w=` -> the app's parser reads the KEY to know which tab to open
    const res = handleRingtoneLink(
      ctxFor(`https://arul.hsrutility.com/r/${RINGTONE_ID}?ref=ABCD1234&lang=ta`),
    );

    expect(res.status).toBe(200);
    const location = await dest(res);
    expect(location.origin + location.pathname).toBe(
      "https://play.google.com/store/apps/details",
    );
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&r=${RINGTONE_ID}&lang=ta`,
    );
  });

  it("still sends a malformed ringtone link to the store, without the junk", async () => {
    const res = handleRingtoneLink(
      ctxFor("https://arul.hsrutility.com/r/not-a-uuid?lang=%3Cscript%3E"),
    );

    expect(res.status).toBe(200);
    const location = await dest(res);
    // Both junk values are dropped but the SECTION the path named survives -> a typo in the id costs the track, not the tab
    expect(location.searchParams.get("referrer")).toBe("screen=ringtones");
  });
});

// A language-only campaign link. The app's manifest filter is a pathPrefix -> `/w/?lang=hi` already opens an install
// This half exists only so the SAME URL does not 404 at everyone who lacks the app
describe("GET /w/ and /r/ without an id (language-only links)", () => {
  it.each([
    ["https://arul.hsrutility.com/w/?lang=hi", "hi"],
    ["https://arul.hsrutility.com/w?lang=hi", "hi"],
    ["https://arul.hsrutility.com/w/?lang=hi-IN", "hi"],
  ])("sends %s to Play carrying only the language", async (url, want) => {
    const res = handleWallpaperLink(ctxFor(url));

    expect(res.status).toBe(200);
    const location = await dest(res);
    expect(location.origin + location.pathname).toBe(
      "https://play.google.com/store/apps/details",
    );
    expect(location.searchParams.get("referrer")).toBe(`lang=${want}`);
  });

  // The PATH is the only thing that says "ringtones", and it does not survive the trip through Play
  // The app sees the referrer and nothing else -> without `screen=` the two URLs arrive identical
  // A fresh install would then land on the feed -> `screen=` is a key the app already reads
  // So this works on builds that shipped before the id-less path meant anything
  it("marks the ringtone path so a fresh install lands on that tab", async () => {
    const res = handleRingtoneLink(
      ctxFor("https://arul.hsrutility.com/r/?lang=ta"),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe("screen=ringtones&lang=ta");
  });

  it("does NOT mark the wallpaper path — it is the language-only shape", async () => {
    const res = handleWallpaperLink(
      ctxFor("https://arul.hsrutility.com/w/?lang=ta"),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe("lang=ta");
  });

  it("a real ringtone id wins over the tab marker", async () => {
    const res = handleRingtoneLink(
      ctxFor(`https://arul.hsrutility.com/r/${RINGTONE_ID}?lang=ta`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `r=${RINGTONE_ID}&lang=ta`,
    );
  });

  it("marks a typo'd ringtone id too — it still named ringtones", async () => {
    const res = handleRingtoneLink(
      ctxFor("https://arul.hsrutility.com/r/not-a-uuid?lang=ta"),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe("screen=ringtones&lang=ta");
  });

  it("still reaches Play when the link carries nothing at all", async () => {
    const res = handleWallpaperLink(ctxFor("https://arul.hsrutility.com/w/"));

    expect(res.status).toBe(200);
    const location = await dest(res);
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    expect(location.searchParams.get("referrer")).toBeNull();
  });
});

// `ilang` is what an in-app SHARE stamps -> the sharer's UI language, honoured only by a FRESH install
// It must land in the referrer as plain `lang=` -> that is the key the app's referrer parser reads
describe("ilang (share install-language)", () => {
  it("folds ilang into the referrer's lang", async () => {
    const res = handleWallpaperLink(
      ctxFor(
        `https://arul.hsrutility.com/w/${WALLPAPER_ID}?ref=ABCD1234&ilang=ta`,
      ),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `ref=ABCD1234&w=${WALLPAPER_ID}&lang=ta`,
    );
  });

  it("normalises ilang exactly like lang", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ilang=TA-in`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `w=${WALLPAPER_ID}&lang=ta`,
    );
  });

  it("drops an ilang outside the six shipped codes", async () => {
    const res = handleWallpaperLink(
      ctxFor(`https://arul.hsrutility.com/w/${WALLPAPER_ID}?ilang=fr`),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(`w=${WALLPAPER_ID}`);
  });

  // An ad creative would never send both -> if one ever does, the explicit ad language is what the campaign paid for
  it("lets an explicit lang beat ilang", async () => {
    const res = handleWallpaperLink(
      ctxFor(
        `https://arul.hsrutility.com/w/${WALLPAPER_ID}?lang=hi&ilang=ta`,
      ),
    );

    const location = await dest(res);
    expect(location.searchParams.get("referrer")).toBe(
      `w=${WALLPAPER_ID}&lang=hi`,
    );
  });
});

// The bare link domain doubles as "get the app" -> but ONLY that host
// The API host shares this Worker -> an API caller must still get a 404, never an app advert
describe("GET / on the link domain", () => {
  const rootCtx = (url: string) => makeCtx({ env: makeEnv(), url });

  it("sends a language-only root link to Play", async () => {
    const res = handleRootLink(
      rootCtx("https://arul.hsrutility.com/?lang=hi"),
    );

    expect(res.status).toBe(200);
    const location = await dest(res);
    expect(location.searchParams.get("id")).toBe("com.hsrutility.arul");
    expect(location.searchParams.get("referrer")).toBe("lang=hi");
  });

  it("sends a bare root link to Play with no referrer", async () => {
    const res = handleRootLink(
      rootCtx("https://arul.hsrutility.com/"),
    );

    expect((await dest(res)).searchParams.get("referrer")).toBeNull();
  });

  it("still 404s on the API host", async () => {
    const res = handleRootLink(
      rootCtx("https://arul-api.hsrutility.com/?lang=hi"),
    );

    expect(res.status).toBe(404);
  });
});
