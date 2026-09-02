/**
 * R2 presigned URLs via aws4fetch — https://developers.cloudflare.com/r2/examples/aws/aws4fetch/
 *
 * aws4fetch is Web Crypto only -> no Node polyfill -> the Cloudflare-recommended client for Workers
 * A PUT presign SIGNS Content-Type -> R2 rejects an upload whose header differs -> the MIME limit is enforced at upload
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
 * encodeURIComponent turns `/` into %2F -> non-standard for S3/R2 and it breaks x-amz-copy-source
 * Encode each segment and rejoin with literal slashes -> the key stays a real path
 */
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

/**
 * Where user submissions live: `user/<sub>/submissions/<name>`.
 *
 * sweep-submissions only considers keys containing the INFIX -> validators must enforce it, not just the prefix
 * An object accepted anywhere else under `user/<sub>/` is invisible to reclamation forever -> its bytes are billed
 */
export const SUBMISSION_PREFIX = "user/";
export const SUBMISSION_INFIX = "/submissions/";

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
 * Catalog pages, written through the R2 BINDING (build-catalog has one; the S3 API is for presigns).
 * The binding has no ACL -> "public-read" is not settable here -> public access is a bucket-level dashboard setting
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

export async function getJsonString(
  bucket: R2Bucket,
  key: string,
): Promise<string | null> {
  const obj = await bucket.get(key);
  if (!obj) return null;
  return obj.text();
}
