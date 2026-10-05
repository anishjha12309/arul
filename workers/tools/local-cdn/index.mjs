/**
 * LOCAL-ONLY CDN for the local stack (docs/local-stack.md). NEVER deploy.
 *
 *   GET|HEAD /<key>                -> the LOCAL bucket's object, else a read-only proxy of the production CDN
 *   GET|HEAD /__s3/<bucket>/<key>  -> the same lookup for the presigned URLs the local Worker mints
 *                                     (local-stack sets R2_ENDPOINT=http://127.0.0.1:8788/__s3); X-Amz-* is ignored
 *
 * Local wins, so seeded statuses and a locally built catalog shadow production; anything missing locally
 * (every wallpaper and ringtone file) streams from upstream so both feeds keep working. Nothing is ever
 * written upstream: GET/HEAD only, and the proxy forwards no body.
 */
const UPSTREAM = "https://arul-cdn.hsrutility.com";
const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);
const S3_PREFIX = "/__s3/";
/** Re-read on every app start so a flag flip or a rebuild shows on the next cold start, not after max-age. */
const ALWAYS_FRESH = new Set(["catalog/version.json", "catalog/app_config.json"]);
const TYPES = {
  mp4: "video/mp4",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  json: "application/json",
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // A deployed copy would answer on a public host -> refuse anything that is not loopback
    if (!LOCAL_HOSTS.has(url.hostname)) return text(403, "local-cdn serves loopback only");
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("local-cdn is read-only", { status: 405, headers: { allow: "GET, HEAD" } });
    }

    let key;
    try {
      key = decodeURIComponent(url.pathname).slice(1);
    } catch {
      return text(400, "bad path");
    }
    const presigned = url.pathname.startsWith(S3_PREFIX);
    if (presigned) {
      const rest = key.slice(S3_PREFIX.length - 1); // "<bucket>/<key>"
      const slash = rest.indexOf("/");
      key = slash >= 0 ? rest.slice(slash + 1) : "";
    }
    if (!key || key.endsWith("/")) return text(404, "not found");

    const local = await serveLocal(env.R2, key, request);
    if (local) return local;
    // A presigned URL's query is an S3 signature for a host that is not upstream -> drop it
    return proxyUpstream(key, presigned ? "" : url.search, request);
  },
};

async function serveLocal(bucket, key, request) {
  const head = await bucket.head(key);
  if (!head) return null;

  const size = head.size;
  const headers = new Headers({
    "content-type": head.httpMetadata?.contentType || typeFor(key),
    "accept-ranges": "bytes",
    etag: head.httpEtag,
    "x-local-cdn": "local",
  });
  const cc = ALWAYS_FRESH.has(key) ? "no-cache" : head.httpMetadata?.cacheControl;
  if (cc) headers.set("cache-control", cc);

  const range = parseRange(request.headers.get("range"), size);
  if (range === "invalid") {
    headers.set("content-range", `bytes */${size}`);
    return new Response(null, { status: 416, headers });
  }
  if (range) {
    headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`);
    headers.set("content-length", String(range.length));
    if (request.method === "HEAD") return new Response(null, { status: 206, headers });
    const obj = await bucket.get(key, { range: { offset: range.offset, length: range.length } });
    if (!obj) return null;
    return new Response(obj.body, { status: 206, headers });
  }
  headers.set("content-length", String(size));
  if (request.method === "HEAD") return new Response(null, { status: 200, headers });
  const obj = await bucket.get(key);
  if (!obj) return null;
  return new Response(obj.body, { status: 200, headers });
}

/** Single-range only (what ExoPlayer and HttpClient send). Null = no/unsupported Range -> full body. */
function parseRange(header, size) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m || (m[1] === "" && m[2] === "")) return null;
  let start;
  let end;
  if (m[1] === "") {
    const suffix = Number(m[2]);
    if (suffix === 0) return "invalid";
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start >= size || end < start) return "invalid";
  return { offset: start, length: end - start + 1 };
}

async function proxyUpstream(key, search, request) {
  const headers = new Headers();
  for (const h of ["range", "if-none-match", "if-modified-since"]) {
    const v = request.headers.get(h);
    if (v) headers.set(h, v);
  }
  const target = `${UPSTREAM}/${key.split("/").map(encodeURIComponent).join("/")}${search}`;
  let res;
  try {
    res = await fetch(target, { method: request.method, headers, redirect: "follow" });
  } catch (err) {
    return text(502, `upstream fetch failed: ${err?.message ?? err}`);
  }
  const out = new Response(request.method === "HEAD" ? null : res.body, res);
  out.headers.set("x-local-cdn", "upstream");
  return out;
}

function typeFor(key) {
  const ext = key.split(".").pop()?.toLowerCase() ?? "";
  return TYPES[ext] ?? "application/octet-stream";
}

function text(status, body) {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}
