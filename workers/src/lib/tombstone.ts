/**
 * Trial tombstones — the one-free-trial guard across account deletions.
 *
 * DELETE /me erases the user's rows -> delete then re-signup would reset trial eligibility -> hash first
 * A consumed trial writes HMAC(google_sub) to `trial_tombstones` -> /auth/login re-derives it on every new user
 * A hit pre-seeds a consumed-trial subscriptions row -> the second account starts with the trial already spent
 * The HMAC is one-way -> no PII is stored, yet the same Google account always re-derives the same hash
 * Rotating TRIAL_TOMBSTONE_SECRET orphans every existing tombstone -> trial farming re-opens -> NEVER rotate
 */

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
