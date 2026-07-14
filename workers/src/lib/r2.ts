/**
 * R2 presigned URL generation via aws4fetch.
 *
 * Uses AwsClient.sign() with signQuery:true to embed credentials in the
 * query string (standard S3 presigned URL pattern).
 * Reference: https://developers.cloudflare.com/r2/examples/aws/aws4fetch/
 *
 * aws4fetch runs entirely on the Web Crypto API — no Node.js required.
 * It is the Cloudflare-recommended lightweight approach for Workers.
 *
 * NOTE on Content-Type in PUT presigns:
 *   When Content-Type is included in the signed request the uploading client
 *   MUST send a matching Content-Type header. R2 will reject mismatches.
 *   We sign with Content-Type so the MIME constraint is enforced at upload time.
 */

import { AwsClient } from "aws4fetch";
import type { Env } from "../env.js";

function makeClient(env: Env): AwsClient {
  return new AwsClient({
    service: "s3",
    region: "auto",
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
  });
}

/**
 * URL-encode an object key for use in a request path / copy-source header while
 * keeping `/` as a real path separator. encodeURIComponent() alone turns `/`
 * into %2F, which is non-standard for S3/R2 (and breaks the CopyObject
 * x-amz-copy-source header). Encode each segment, rejoin with literal slashes.
 */
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

/**
 * Generate a presigned GET URL for a private R2 object.
 * @param env     Worker environment
 * @param key     R2 object key
 * @param ttlSecs URL validity window in seconds (default: 300 = 5 minutes)
 */
export async function presignGet(
  env: Env,
  key: string,
  ttlSecs = 300,
): Promise<string> {
  const client = makeClient(env);
  const endpoint = env.R2_ENDPOINT.replace(/\/$/, "");
  const url = `${endpoint}/${env.R2_BUCKET}/${encodeKey(key)}?X-Amz-Expires=${ttlSecs}`;

  const signed = await client.sign(new Request(url), {
    aws: { signQuery: true },
  });
  return signed.url.toString();
}

/**
 * Generate a presigned PUT URL for a private R2 object.
 * @param env         Worker environment
 * @param key         R2 object key
 * @param contentType MIME type — included in the signature; uploader MUST match
 * @param ttlSecs     URL validity window in seconds (default: 300 = 5 minutes)
 */
export async function presignPut(
  env: Env,
  key: string,
  contentType: string,
  ttlSecs = 300,
): Promise<string> {
  const client = makeClient(env);
  const endpoint = env.R2_ENDPOINT.replace(/\/$/, "");
  const url = `${endpoint}/${env.R2_BUCKET}/${encodeKey(key)}?X-Amz-Expires=${ttlSecs}`;

  const signed = await client.sign(
    new Request(url, {
      method: "PUT",
      headers: { "Content-Type": contentType },
    }),
    { aws: { signQuery: true } },
  );
  return signed.url.toString();
}

/**
 * Server-side copy of one R2 object to another key via S3 CopyObject
 * (x-amz-copy-source). The bytes never transit the Worker — R2 copies internally.
 * Used by submission approval to move bytes from the user/<sub>/submissions/…
 * path (which leaks the submitter id) to a canonical catalog key.
 *
 * @param contentType when given, the copy REPLACES the content-type metadata.
 */
export async function r2Copy(
  env: Env,
  srcKey: string,
  dstKey: string,
  contentType?: string,
): Promise<void> {
  const client = makeClient(env);
  const endpoint = env.R2_ENDPOINT.replace(/\/$/, "");
  const url = `${endpoint}/${env.R2_BUCKET}/${encodeKey(dstKey)}`;

  const headers: Record<string, string> = {
    "x-amz-copy-source": `/${env.R2_BUCKET}/${encodeKey(srcKey)}`,
  };
  if (contentType) {
    headers["Content-Type"] = contentType;
    headers["x-amz-metadata-directive"] = "REPLACE";
  }

  const signed = await client.sign(new Request(url, { method: "PUT", headers }));
  const res = await fetch(signed);
  if (!res.ok) {
    throw new Error(`R2 copy failed ${res.status}: ${await res.text()}`);
  }
}

/**
 * Write a JSON object to R2 as a public-read object (catalog pages).
 * Uses the R2 Workers binding (env.R2_BUCKET is accessed via wrangler binding).
 * This function is used by build-catalog where we have the R2 binding, not S3 API.
 *
 * NOTE: The R2 Workers binding does not support ACL. Public access is enabled
 * at the bucket level in the Cloudflare dashboard (Settings → Public access).
 */
export async function putPublicJson(
  bucket: R2Bucket,
  key: string,
  body: unknown,
  cacheControl = "public, max-age=60",
): Promise<void> {
  await bucket.put(key, JSON.stringify(body), {
    httpMetadata: { contentType: "application/json", cacheControl },
  });
}

/** Read an R2 object as a string (used by build-catalog version checks). */
export async function getJsonString(
  bucket: R2Bucket,
  key: string,
): Promise<string | null> {
  const obj = await bucket.get(key);
  if (!obj) return null;
  return obj.text();
}
