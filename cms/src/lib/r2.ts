/**
 * R2 presigned URL generation + server-side copy via aws4fetch (S3 API).
 *
 * Copied from the shipped app Workers, parameterized by BUCKET NAME: one
 * account-scoped R2 token covers both apps' buckets; the bucket in each URL
 * comes from the caller's AppDef (registry), never from a global.
 *
 * NOTE on Content-Type in PUT presigns: when Content-Type is included in the
 * signed request the uploading client MUST send a matching header — R2 rejects
 * mismatches, which is exactly how the MIME constraint is enforced at upload.
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
 * URL-encode an object key while keeping `/` as a real path separator
 * (encodeURIComponent alone breaks the CopyObject x-amz-copy-source header).
 */
function encodeKey(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

/** Presigned GET for a private R2 object (submission previews). */
export async function presignGet(
  env: Env,
  bucket: string,
  key: string,
  ttlSecs = 300,
): Promise<string> {
  const client = makeClient(env);
  const endpoint = env.R2_ENDPOINT.replace(/\/$/, "");
  const url = `${endpoint}/${bucket}/${encodeKey(key)}?X-Amz-Expires=${ttlSecs}`;

  const signed = await client.sign(new Request(url), {
    aws: { signQuery: true },
  });
  return signed.url.toString();
}

/** Presigned PUT — browser uploads bytes directly to R2 (zero-egress). */
export async function presignPut(
  env: Env,
  bucket: string,
  key: string,
  contentType: string,
  ttlSecs = 300,
): Promise<string> {
  const client = makeClient(env);
  const endpoint = env.R2_ENDPOINT.replace(/\/$/, "");
  const url = `${endpoint}/${bucket}/${encodeKey(key)}?X-Amz-Expires=${ttlSecs}`;

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
 * (x-amz-copy-source) — the bytes never transit the Worker. Used by submission
 * approval to move bytes from user/<sub>/submissions/… to a canonical key.
 *
 * @param contentType when given, the copy REPLACES the content-type metadata.
 */
export async function r2Copy(
  env: Env,
  bucket: string,
  srcKey: string,
  dstKey: string,
  contentType?: string,
): Promise<void> {
  const client = makeClient(env);
  const endpoint = env.R2_ENDPOINT.replace(/\/$/, "");
  const url = `${endpoint}/${bucket}/${encodeKey(dstKey)}`;

  const headers: Record<string, string> = {
    "x-amz-copy-source": `/${bucket}/${encodeKey(srcKey)}`,
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
