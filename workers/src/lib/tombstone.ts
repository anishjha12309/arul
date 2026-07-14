/**
 * Trial tombstones — the one-free-trial guard across account deletions.
 *
 * DELETE /me removes the user's rows entirely (PII gone), but first records
 * HMAC-SHA256(google_sub, TRIAL_TOMBSTONE_SECRET) in `trial_tombstones` when
 * the trial was consumed. /auth/login's new-user branch checks the same hash
 * and pre-seeds a consumed-trial subscriptions row, so delete → re-signup
 * never resets trial eligibility.
 *
 * The HMAC is one-way: the tombstone stores no PII and cannot be reversed to
 * a Google account, but the SAME Google account always re-derives the same
 * hash. TRIAL_TOMBSTONE_SECRET must therefore NEVER be rotated — a new secret
 * would orphan every existing tombstone and re-open trial farming.
 */

/** HMAC-SHA256(googleSub, secret) as lowercase hex. */
export async function hashGoogleSub(
  googleSub: string,
  secret: string,
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(googleSub));
  return [...new Uint8Array(sig)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
