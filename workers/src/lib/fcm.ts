/**
 * FCM HTTP v1 — mint an OAuth access token from the service account, send one campaign message.
 * https://firebase.google.com/docs/cloud-messaging/send/v1-api · https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages
 *
 * NOTIFICATION MESSAGES BY DEFAULT, and there is no Dart background handler anywhere in the app.
 * ~70% of this base runs a vivo/Xiaomi/OPPO/realme battery manager that kills a background isolate on
 * sight; a notification message is posted by Google Play services without waking the app at all, so it
 * survives everything short of a user force-stop. It is also what keeps `priority: HIGH` honest —
 * Android 13 downgrades an app that consistently sends high-priority messages producing no
 * notification, and every message here produces one.
 *
 * THE ONE EXCEPTION IS A COLOURED CAMPAIGN to a build that carries the native renderer. FCM's
 * `color` tints the icon only, so a card background means the app draws the notification itself:
 * a data-only message handled by `ArulMessagingService` (Kotlin, no isolate), which still posts one
 * notification per message. Every other campaign, and every build below COLOR_MIN_BUILD, keeps the
 * notification-message path unchanged.
 *
 * IDENTITY IS THE `fid`, THE TARGET IS THE `token`, and they are not the same job. The REST reference
 * marks `message.token` deprecated in favour of `message.fid`, so this shipped targeting the fid —
 * and a real device rejected it. Measured on a registered phone, identical payload, same minute:
 *     { fid:   "eme780tIRqaKehWqThsmOX" }  -> HTTP 404 { errorCode: "UNREGISTERED" }
 *     { token: "eme780tIRqaKehWqThsmOX:APA91b..." } -> HTTP 200
 * So `fid` addressing is not actually serving for this project today whatever the reference says.
 * SEND_BY is the single switch; retest both before flipping it back, and never hedge with a
 * per-device fallback — a silent second path is how "it works on some phones" starts.
 *
 * The fid still earns its place as the PRIMARY KEY: it survives token rotation, so a phone keeps one
 * row across a refresh instead of accumulating one per token.
 *
 * `validate_only` IS WHAT THE REGISTRY PRUNE RELIES ON (cron/push-dispatch.ts). FCM runs a
 * validate-only request through every check, the target included, and delivers nothing. Proven on
 * the owner's phone on 2026-09-17: the live token answered HTTP 200 with
 * `name: …/messages/fake_message_id` and the drawer stayed empty; after an uninstall and reinstall
 * the old token answered HTTP 404 `{ errorCode: "UNREGISTERED" }` ("NotRegistered") within a minute,
 * and the new one 200 again. So a dry run reads exactly like a send to `isDeadRegistration`, and the
 * registry can be checked between campaigns instead of only by one.
 */

import { importPKCS8, SignJWT } from "jose";
import type { Env } from "../env.js";

/** Which target field the message carries. One value, never a per-device fallback (see header). */
const SEND_BY: "fid" | "token" = "token";

const OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const KV_TOKEN_KEY = "fcm:access_token";

/** Google mints a 1 h token; cache it five minutes short so a send never races the expiry. */
const TOKEN_SKEW_SECONDS = 300;

/** The dedicated campaign channel. Immutable once created on a device — app + payload must agree. */
export const PUSH_CHANNEL_ID = "arul_updates_v1";

/** Arul gold. Mirrors NotificationService._accent and @color/notification_accent — three copies. */
const PUSH_ACCENT = "#D4A017";

/** Monochrome status-bar silhouette; resolved BY NAME on the device, so keep.xml keeps it alive. */
const PUSH_ICON = "ic_notification";

/**
 * versionCode 76 is the first build carrying `ArulMessagingService`, the native renderer for coloured
 * campaigns. Below it a data-only message would produce no notification at all, so those phones get
 * the plain notification message instead.
 */
export const COLOR_MIN_BUILD = 76;

/**
 * The build number inside a registered versionCode. Flutter's per-ABI builds report
 * 1000 × abiCode + build, and they are in the field: the one phone in the production registry on
 * 2026-09-14 reported 2075 for build 75. Compared raw, that passes `>= 76` and a build with no
 * renderer would be sent a data-only message it cannot show — so compare this, never the raw value.
 */
export function buildNumber(appBuild: number): number {
  return appBuild % 1000;
}

export interface PushDevice {
  fid: string;
  token: string | null;
  lang: string;
  app_build?: number | null;
}

export interface PushCampaign {
  id: string;
  /** { "en": { title, body }, "ta": {…} } — English is required and is every other locale's fallback. */
  texts: Record<string, { title?: string; body?: string } | undefined>;
  dest: string;
  dest_id: string | null;
  image_url: string | null;
  /** `#rrggbb` or null. Non-null switches builds >= COLOR_MIN_BUILD to the data-only path. */
  color?: string | null;
  /** 1 | 6 | 24 -> `android.ttl`. Rows written before db/schema/18 read as the column default, 24. */
  expires_hours?: number;
}

export type PushResult =
  | { ok: true; name: string }
  | { ok: false; status: number; code: string; message: string };

/**
 * A Google OAuth2 access token for the FCM scope, cached in KV.
 *
 * The service-account key arrives through `wrangler secret bulk` from a JSON file, so its PEM holds
 * literal backslash-n sequences rather than newlines and `importPKCS8` rejects it outright. Normalise
 * exactly that and nothing else — every other secret in this Worker is compared untrimmed, and a PEM
 * that needed trimming would be a different fault worth seeing.
 */
export async function getFcmAccessToken(env: Env): Promise<string> {
  const cached = await env.KV.get(KV_TOKEN_KEY);
  if (cached) return cached;

  const clientEmail = env.FCM_SA_CLIENT_EMAIL ?? "";
  const rawKey = env.FCM_SA_PRIVATE_KEY ?? "";
  if (!clientEmail || !rawKey) {
    throw new Error("FCM service-account secrets are not set (FCM_SA_CLIENT_EMAIL / FCM_SA_PRIVATE_KEY)");
  }

  const pem = rawKey.replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new SignJWT({ scope: FCM_SCOPE })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(clientEmail)
    .setAudience(OAUTH_TOKEN_URL)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const res = await fetch(OAUTH_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const body = (await res.json().catch(() => null)) as
    | { access_token?: string; expires_in?: number; error_description?: string; error?: string }
    | null;
  if (!res.ok || !body?.access_token) {
    throw new Error(
      `FCM token exchange failed: HTTP ${res.status} ${body?.error_description ?? body?.error ?? ""}`.trim(),
    );
  }

  const ttl = Math.max(60, (body.expires_in ?? 3600) - TOKEN_SKEW_SECONDS);
  await env.KV.put(KV_TOKEN_KEY, body.access_token, { expirationTtl: ttl });
  return body.access_token;
}

/** The phone's own language if the editor wrote it, else English. Never a partially-filled locale. */
export function textFor(
  campaign: PushCampaign,
  lang: string,
): { title: string; body: string } {
  const own = campaign.texts?.[lang];
  const en = campaign.texts?.["en"];
  const pick = own?.title || own?.body ? own : en;
  return { title: pick?.title ?? "", body: pick?.body ?? "" };
}

/**
 * Send ONE campaign message to ONE device. Never throws — a transport failure is a `false` result so
 * the delivery row records it and the campaign keeps draining.
 *
 * Retries ONCE after a second on 429/5xx; a 4xx is a fact about the device or the payload and a
 * second identical request cannot change it.
 */
export async function sendPush(
  env: Env,
  accessToken: string,
  device: PushDevice,
  campaign: PushCampaign,
): Promise<PushResult> {
  const projectId = env.FIREBASE_PROJECT_ID ?? "";
  if (!projectId) {
    return { ok: false, status: 0, code: "NO_PROJECT_ID", message: "FIREBASE_PROJECT_ID is not set" };
  }
  // A row with no token cannot be addressed while SEND_BY is "token". Fail the delivery with a
  // reason rather than sending the fid in the token field: that comes back UNREGISTERED, which the
  // caller reads as "dead registration" and DELETES a row that was only ever missing one column.
  if (SEND_BY === "token" && !device.token) {
    return { ok: false, status: 0, code: "NO_TOKEN", message: "Device row carries no FCM token" };
  }
  const target =
    SEND_BY === "fid" ? { fid: device.fid } : { token: device.token as string };
  const { title, body } = textFor(campaign, device.lang);

  // FCM requires every `data` VALUE to be a string; the 4096-byte payload cap is far away at this size.
  const data: Record<string, string> = {
    campaign_id: campaign.id,
    dest: campaign.dest,
    lang: device.lang,
  };
  if (campaign.dest_id) data["id"] = campaign.dest_id;

  const ttl = `${(campaign.expires_hours ?? 24) * 3600}s`;
  // The console's Messaging -> Reports tab filters on this, which is the owner's independent read
  // of Sent/Received/Opens against the CMS's own numbers. Pattern: ^[a-zA-Z0-9-_.~%]{1,50}$ — a UUID fits.
  const fcmOptions = { analytics_label: campaign.id };

  const rendersColor =
    !!campaign.color && device.app_build != null && buildNumber(device.app_build) >= COLOR_MIN_BUILD;

  const plain = {
    ...target,
    notification: {
      title,
      body,
      ...(campaign.image_url ? { image: campaign.image_url } : {}),
    },
    data,
    fcm_options: fcmOptions,
    android: {
      priority: "HIGH",
      ttl,
      // No collapse_key: FCM documents NOTIFICATION messages as always collapsible, keyed by package,
      // and ignores the field. A phone offline across two campaigns gets only the LATEST (measured with
      // a shared key and with a per-campaign key alike: 2 sent in airplane mode, 1 arrived, both rows
      // "sent"). Only data messages avoid it. `tag` de-dupes the drawer.
      notification: {
        channel_id: PUSH_CHANNEL_ID,
        icon: PUSH_ICON,
        color: PUSH_ACCENT,
        tag: campaign.id,
        // Applies on Android 7.1 and lower ONLY — from 8.0 the channel's importance decides.
        notification_priority: "PRIORITY_DEFAULT",
      },
    },
  };

  const coloured = () => ({
    ...target,
    // Data-only: no `notification` block, so FCM hands the message to ArulMessagingService, which
    // posts it with the colour. The keys the tap path reads stay exactly as the plain path sends them;
    // the rest are what the service needs to draw the card.
    data: {
      ...data,
      title,
      body,
      ...(campaign.image_url ? { image: campaign.image_url } : {}),
      color: campaign.color as string,
      channel_id: PUSH_CHANNEL_ID,
      tag: campaign.id,
    },
    fcm_options: fcmOptions,
    android: {
      priority: "HIGH",
      ttl,
      // Data messages DO honour collapse_key. Per campaign, so a phone offline across two campaigns
      // gets both, while a genuine duplicate of one campaign still collapses.
      collapse_key: campaign.id,
    },
  });

  const message = rendersColor ? coloured() : plain;

  const first = await postMessage(projectId, accessToken, { message });
  if (first.ok) return first;
  const retryable = first.status === 429 || first.status >= 500 || first.status === 0;
  if (!retryable) return first;
  await new Promise((r) => setTimeout(r, 1000));
  return postMessage(projectId, accessToken, { message });
}

/**
 * Ask FCM whether a token is still a live registration WITHOUT delivering anything (see header).
 *
 * No retry: a transient error leaves the row where it is and the next pass asks again. The texts
 * are never shown — they are there because a message needs a body to be validated at all.
 */
export async function validateToken(
  env: Env,
  accessToken: string,
  token: string,
): Promise<PushResult> {
  const projectId = env.FIREBASE_PROJECT_ID ?? "";
  if (!projectId) {
    return { ok: false, status: 0, code: "NO_PROJECT_ID", message: "FIREBASE_PROJECT_ID is not set" };
  }
  return postMessage(projectId, accessToken, {
    validate_only: true,
    message: { token, notification: { title: "dry run", body: "dry run" } },
  });
}

/**
 * One POST to messages:send, read into a PushResult. Never throws. The send and the dry run share
 * it so a dead registration is spelled the same way on both paths — `isDeadRegistration` reads one.
 */
async function postMessage(
  projectId: string,
  accessToken: string,
  body: Record<string, unknown>,
): Promise<PushResult> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch (err) {
    return { ok: false, status: 0, code: "UNAVAILABLE", message: String(err) };
  }
  const parsed = (await res.json().catch(() => null)) as
    | { name?: string; error?: { message?: string; status?: string; details?: { errorCode?: string }[] } }
    | null;
  if (res.ok) return { ok: true, name: parsed?.name ?? "" };
  const detail = parsed?.error?.details?.find((d) => typeof d?.errorCode === "string");
  return {
    ok: false,
    status: res.status,
    code: detail?.errorCode ?? parsed?.error?.status ?? `HTTP_${res.status}`,
    message: parsed?.error?.message ?? `HTTP ${res.status}`,
  };
}

/**
 * Firebase's stated rule: a 404 UNREGISTERED or a 400 INVALID_ARGUMENT naming the target means the
 * registration is dead and the sender must stop keeping it. Anything else is transient and the row
 * stays — a quota or an outage must never empty the registry.
 */
export function isDeadRegistration(result: PushResult): boolean {
  if (result.ok) return false;
  if (result.status === 404 && result.code === "UNREGISTERED") return true;
  return result.status === 400 && result.code === "INVALID_ARGUMENT";
}
