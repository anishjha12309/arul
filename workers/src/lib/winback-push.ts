/**
 * The win-back push: ONE push the Worker sends by itself to a payer who revoked their mandate outside the app, landing
 * on the ₹99 winback (docs/push.md §Win-back). Every rule of it lives here -> the parks, the sender and the tests
 * read one copy
 */

import type postgres from "postgres";
import { WINBACK_OFFER } from "./pricing.js";

type Sql = postgres.Sql;
type Fragment = postgres.PendingQuery<postgres.Row[]>;

/** Long enough not to read as "we saw that", short enough to land while the choice is still fresh. */
export const WINBACK_DELAY_MS = 20 * 60 * 1000;

/** A paid revoker still has paid days, and an accepted ₹99 restarts the month from that day -> ask a day before the end. */
export const PAID_LEAD_MS = 24 * 60 * 60 * 1000;

/** Older than this past due is skipped, never sent -> a switch flipped back on or an outage must not end in a blast. */
export const STALE_AFTER_MS = 24 * 60 * 60 * 1000;

/**
 * The versionCode of the release whose /premium opens the ₹99 sheet from `offer=winback_99` -> older builds land on
 * the ₹199 Resubscribe page first, so they are never sent one. Raise it to that release's code before going live
 * 98 is also the first whose decline only closes the sheet; an older one's started a ₹199 checkout nobody tapped
 */
export const WINBACK_MIN_BUILD = 98;

/** A lapse earns one push a day for this many days, day 0 being the moment premium ran out (owner). */
export const SERIES_DAYS = 14;

const DAY_MS = 24 * 60 * 60 * 1000;

/** Never interrupt a night: cron time is UTC and India keeps no DST, so a fixed +05:30 is exact. */
const IST_OFFSET_MS = (5 * 60 + 30) * 60 * 1000;
const QUIET_FROM_HOUR = 22;
const QUIET_UNTIL_HOUR = 9;

/** A delivery's TTL (`push_campaigns.expires_hours`, CHECK 1|6|24) -> an offline phone that wakes later missed the moment. */
export const WINBACK_EXPIRES_HOURS = 6;

export type WinbackGroup = "trial" | "paid";

export type WinbackSource =
  | "webhook"
  | "status_route"
  | "offer_gate"
  | "pass_a"
  | "pass_b"
  | "pass_d"
  | "legacy_reconcile";

/** What a park writes into `winback_pushes` alongside the status change. */
export interface WinbackRecord {
  state: "queued" | "skipped";
  skipReason: "in_app_cancel" | "merchant_cancel" | null;
  phonepeState: string;
  detectedBy: WinbackSource | "in_app_cancel";
}

/**
 * REVOKED is the payer's own act in their UPI app -> the one state that queues a push. CANCELLED is the merchant
 * cancel API, which only we call -> recorded, never sent. EXPIRED, FAILED or a missing state is nobody's choice -> no row.
 * The offer gate meets a revoke while the person is inside the in-app cancel offer -> they are already looking at it
 */
export function winbackRecordFor(
  phonepeState: string | null | undefined,
  detectedBy: WinbackSource,
): WinbackRecord | null {
  const state = phonepeState ?? null;
  if (state !== "REVOKED" && state !== "CANCELLED") return null;
  if (detectedBy === "offer_gate") {
    return { state: "skipped", skipReason: "in_app_cancel", phonepeState: state, detectedBy };
  }
  if (state === "CANCELLED") {
    return { state: "skipped", skipReason: "merchant_cancel", phonepeState: state, detectedBy };
  }
  return { state: "queued", skipReason: null, phonepeState: state, detectedBy };
}

/**
 * Wrap a park `UPDATE … RETURNING user_id, merchant_subscription_id, prior_status` so the row change and its
 * win-back row commit together: a failed insert cannot lose the push, a redelivery cannot double it. Only a live plan
 * qualifies -> a pending claim's own id dying is a failed setup, and an already-cancelled row was cancelled in-app
 */
export function withWinbackRecord(sql: Sql, update: Fragment, record: WinbackRecord | null): Fragment {
  if (!record) return update;
  const resolvedAt = record.state === "skipped" ? sql`now()` : sql`NULL::timestamptz`;
  return sql`
    WITH c AS (${update}),
    w AS (
      INSERT INTO winback_pushes
        (mandate_id, user_id, prior_status, phonepe_state, detected_by, state, skip_reason, resolved_at)
      SELECT c.merchant_subscription_id, c.user_id, c.prior_status, ${record.phonepeState}, ${record.detectedBy},
             ${record.state}, ${record.skipReason}, ${resolvedAt}
      FROM c
      WHERE c.prior_status IN ('trialing', 'active', 'paused')
        AND c.merchant_subscription_id IS NOT NULL
      ON CONFLICT (mandate_id) DO NOTHING
    )
    SELECT * FROM c
  `;
}

/**
 * An in-app cancel claims its mandates' slots BEFORE it calls PhonePe -> our own cancel's webhook can land before
 * handleCancel's UPDATE and still read a live row. Best effort: a failed claim must never block a cancel
 */
export async function claimInAppCancel(
  sql: Sql,
  userId: string,
  mandateIds: (string | null)[],
): Promise<void> {
  for (const mandateId of new Set(mandateIds)) {
    if (!mandateId) continue;
    await sql`
      INSERT INTO winback_pushes (mandate_id, user_id, detected_by, state, skip_reason, resolved_at)
      VALUES (${mandateId}, ${userId}, 'in_app_cancel', 'skipped', 'in_app_cancel', now())
      ON CONFLICT (mandate_id) DO NOTHING
    `.catch((err: unknown) => {
      console.error(`[winback] in-app cancel claim for ${mandateId} failed:`, err);
    });
  }
}

export function isQuietHourIST(now: Date): boolean {
  const hour = new Date(now.getTime() + IST_OFFSET_MS).getUTCHours();
  return hour >= QUIET_FROM_HOUR || hour < QUIET_UNTIL_HOUR;
}

/** Midnight IST of `now`'s day, as an instant -> "one win-back a day" means India's day, not UTC's. */
export function istDayStart(now: Date): Date {
  const ist = now.getTime() + IST_OFFSET_MS;
  return new Date(ist - (ist % DAY_MS) - IST_OFFSET_MS);
}

/** The series day `now` falls on for a lapse at `lapsedAt`, or null outside the series. */
export function seriesDay(lapsedAt: Date, now: Date): number | null {
  const elapsed = now.getTime() - lapsedAt.getTime();
  if (elapsed < 0) return null;
  const day = Math.floor(elapsed / DAY_MS);
  return day < SERIES_DAYS ? day : null;
}

/** The month a win-back row counts under, as the owner reads the CMS: India's calendar, not UTC's. */
export function monthKeyIST(now: Date): string {
  const ist = new Date(now.getTime() + IST_OFFSET_MS);
  return `${ist.getUTCFullYear()}-${String(ist.getUTCMonth() + 1).padStart(2, "0")}`;
}

export function winbackGroup(priorStatus: string | null): WinbackGroup {
  return priorStatus === "trialing" ? "trial" : "paid";
}

export function autoKeyFor(group: WinbackGroup, now: Date): string {
  return `winback:${group}:${monthKeyIST(now)}`;
}

/** One row per series day per IST month, `winback:day01:2026-10`, so the CMS reads which day still earns its push. */
export function seriesAutoKey(day: number, now: Date): string {
  return `winback:day${String(day + 1).padStart(2, "0")}:${monthKeyIST(now)}`;
}

/** The fields of one due row the decision reads -> `phones` ignores the build gate, `newPhones` applies it. */
export interface DueWinback {
  group: WinbackGroup;
  mandateId: string;
  dueAt: Date;
  liveMandateId: string | null;
  status: string | null;
  eligible: boolean;
  phones: number;
  newPhones: number;
}

export type WinbackSkip =
  | "series"
  | "stale"
  | "live_again"
  | "new_setup"
  | "not_eligible"
  | "no_phone"
  | "disabled"
  | "old_build";

/**
 * First match wins. `disabled` sits AFTER the phone check -> the dark-launch baseline is the same "eligible and
 * reachable" group that later gets pushes, so the two periods compare like with like
 */
export function winbackDecision(row: DueWinback, now: Date, live: boolean): WinbackSkip | "send" {
  // A paid revoker still has paid days; the daily series asks once they run out (owner)
  if (row.group === "paid") return "series";
  if (row.dueAt.getTime() < now.getTime() - STALE_AFTER_MS) return "stale";
  const sameMandate = row.liveMandateId === row.mandateId;
  // A debit already in flight settles with no status guard -> the revoked mandate's row can read live again
  if (sameMandate && (row.status === "trialing" || row.status === "active" || row.status === "paused")) {
    return "live_again";
  }
  if (row.status !== null && (!sameMandate || row.status === "pending")) return "new_setup";
  if (!row.eligible) return "not_eligible";
  if (row.phones === 0) return "no_phone";
  if (!live) return "disabled";
  if (row.newPhones === 0) return "old_build";
  return "send";
}

type Lang = "en" | "ta" | "te" | "kn" | "ml" | "hi";
type Texts = Record<Lang, { title: string; body: string }>;

/**
 * No time and no "keep": an accepted winback charges ₹99 on approval and starts a fresh month that day, a paused row
 * has no premium, and the 09:00 hold can land a push just after the period ended. No countdown, no guilt (CCPA)
 */
const WINBACK_BODY: Record<Lang, string> = {
  en: "Your autopay is off. Premium is ₹99 a month for you, instead of ₹199. Cancel anytime in the app.",
  ta: "உங்கள் ஆட்டோபே நிறுத்தப்பட்டுள்ளது. உங்களுக்கு பிரீமியம் ₹199-க்கு பதிலாக மாதம் ₹99. ஆப்பில் எப்போது வேண்டுமானாலும் ரத்து செய்யலாம்.",
  te: "మీ ఆటోపే ఆఫ్ అయింది. మీకు ప్రీమియం ₹199 బదులు నెలకు ₹99. యాప్‌లో ఎప్పుడైనా రద్దు చేయవచ్చు.",
  kn: "ನಿಮ್ಮ ಆಟೋಪೇ ಆಫ್ ಆಗಿದೆ. ನಿಮಗೆ ಪ್ರೀಮಿಯಂ ₹199 ಬದಲು ತಿಂಗಳಿಗೆ ₹99. ಆ್ಯಪ್‌ನಲ್ಲಿ ಯಾವಾಗ ಬೇಕಾದರೂ ರದ್ದು ಮಾಡಿ.",
  ml: "നിങ്ങളുടെ ഓട്ടോപേ ഓഫാണ്. നിങ്ങൾക്ക് പ്രീമിയം ₹199-ന് പകരം പ്രതിമാസം ₹99. ആപ്പിൽ എപ്പോൾ വേണമെങ്കിലും റദ്ദാക്കാം.",
  hi: "आपका ऑटोपे बंद है। आपके लिए प्रीमियम ₹199 की जगह ₹99/माह। ऐप में कभी भी रद्द करें।",
};

const WINBACK_TITLE: Record<WinbackGroup, Record<Lang, string>> = {
  trial: {
    en: "Liked your Arul Premium trial?",
    ta: "Arul Premium டிரையல் பிடித்ததா?",
    te: "Arul Premium ట్రయల్ నచ్చిందా?",
    kn: "Arul Premium ಟ್ರಯಲ್ ಇಷ್ಟವಾಯಿತೇ?",
    ml: "Arul Premium ട്രയൽ ഇഷ്ടപ്പെട്ടോ?",
    hi: "Arul Premium का ट्रायल पसंद आया?",
  },
  paid: {
    en: "Arul Premium for ₹99 a month",
    ta: "மாதம் ₹99-க்கு Arul Premium",
    te: "నెలకు ₹99కే Arul Premium",
    kn: "ತಿಂಗಳಿಗೆ ₹99ಕ್ಕೆ Arul Premium",
    ml: "പ്രതിമാസം ₹99-ന് Arul Premium",
    hi: "Arul Premium ₹99/माह में",
  },
};

export function winbackTexts(group: WinbackGroup): Texts {
  const langs = Object.keys(WINBACK_BODY) as Lang[];
  return Object.fromEntries(
    langs.map((lang) => [lang, { title: WINBACK_TITLE[group][lang], body: WINBACK_BODY[lang] }]),
  ) as Texts;
}

/**
 * The series' three messages, taking turns by day so fourteen pushes never read as one nag repeated. Nothing about
 * autopay: a lapse can be a failed debit. No countdown, no guilt, the price and "cancel anytime" in each (CCPA)
 */
const SERIES_MESSAGES: Texts[] = [
  {
    en: {
      title: "Arul Premium for ₹99 a month",
      body: "Premium is ₹99 a month for you, instead of ₹199. Cancel anytime in the app.",
    },
    ta: {
      title: "மாதம் ₹99-க்கு Arul Premium",
      body: "உங்களுக்கு பிரீமியம் ₹199-க்கு பதிலாக மாதம் ₹99. ஆப்பில் எப்போது வேண்டுமானாலும் ரத்து செய்யலாம்.",
    },
    te: {
      title: "నెలకు ₹99కే Arul Premium",
      body: "మీకు ప్రీమియం ₹199 బదులు నెలకు ₹99. యాప్‌లో ఎప్పుడైనా రద్దు చేయవచ్చు.",
    },
    kn: {
      title: "ತಿಂಗಳಿಗೆ ₹99ಕ್ಕೆ Arul Premium",
      body: "ನಿಮಗೆ ಪ್ರೀಮಿಯಂ ₹199 ಬದಲು ತಿಂಗಳಿಗೆ ₹99. ಆ್ಯಪ್‌ನಲ್ಲಿ ಯಾವಾಗ ಬೇಕಾದರೂ ರದ್ದು ಮಾಡಿ.",
    },
    ml: {
      title: "പ്രതിമാസം ₹99-ന് Arul Premium",
      body: "നിങ്ങൾക്ക് പ്രീമിയം ₹199-ന് പകരം പ്രതിമാസം ₹99. ആപ്പിൽ എപ്പോൾ വേണമെങ്കിലും റദ്ദാക്കാം.",
    },
    hi: {
      title: "Arul Premium ₹99/माह में",
      body: "आपके लिए प्रीमियम ₹199 की जगह ₹99/माह। ऐप में कभी भी रद्द करें।",
    },
  },
  {
    en: {
      title: "Set any wallpaper or ringtone",
      body: "Every wallpaper, ringtone and status for ₹99 a month. Cancel anytime in the app.",
    },
    ta: {
      title: "எந்த வால்பேப்பர், ரிங்டோனையும் அமைக்கலாம்",
      body: "எல்லா வால்பேப்பர், ரிங்டோன், ஸ்டேட்டஸும் மாதம் ₹99-க்கு. ஆப்பில் எப்போது வேண்டுமானாலும் ரத்து செய்யலாம்.",
    },
    te: {
      title: "ఏ వాల్‌పేపర్, రింగ్‌టోన్ అయినా సెట్ చేయండి",
      body: "అన్ని వాల్‌పేపర్‌లు, రింగ్‌టోన్‌లు, స్టేటస్‌లు నెలకు ₹99కే. యాప్‌లో ఎప్పుడైనా రద్దు చేయవచ్చు.",
    },
    kn: {
      title: "ಯಾವುದೇ ವಾಲ್‌ಪೇಪರ್, ರಿಂಗ್‌ಟೋನ್ ಸೆಟ್ ಮಾಡಿ",
      body: "ಎಲ್ಲಾ ವಾಲ್‌ಪೇಪರ್, ರಿಂಗ್‌ಟೋನ್, ಸ್ಟೇಟಸ್ ತಿಂಗಳಿಗೆ ₹99ಕ್ಕೆ. ಆ್ಯಪ್‌ನಲ್ಲಿ ಯಾವಾಗ ಬೇಕಾದರೂ ರದ್ದು ಮಾಡಿ.",
    },
    ml: {
      title: "ഏത് വാൾപേപ്പറും റിംഗ്ടോണും സെറ്റ് ചെയ്യൂ",
      body: "എല്ലാ വാൾപേപ്പറും റിംഗ്ടോണും സ്റ്റാറ്റസും പ്രതിമാസം ₹99-ന്. ആപ്പിൽ എപ്പോൾ വേണമെങ്കിലും റദ്ദാക്കാം.",
    },
    hi: {
      title: "कोई भी वॉलपेपर या रिंगटोन लगाएँ",
      body: "सारे वॉलपेपर, रिंगटोन और स्टेटस ₹99/माह में। ऐप में कभी भी रद्द करें।",
    },
  },
  {
    en: {
      title: "Share any status",
      body: "Share and save status videos with Premium for ₹99 a month. Cancel anytime in the app.",
    },
    ta: {
      title: "எந்த ஸ்டேட்டஸையும் பகிரலாம்",
      body: "மாதம் ₹99 பிரீமியத்தில் ஸ்டேட்டஸ் வீடியோக்களைப் பகிரலாம், சேமிக்கலாம். ஆப்பில் எப்போது வேண்டுமானாலும் ரத்து செய்யலாம்.",
    },
    te: {
      title: "ఏ స్టేటస్ అయినా షేర్ చేయండి",
      body: "నెలకు ₹99 ప్రీమియంతో స్టేటస్ వీడియోలు షేర్ చేయండి, సేవ్ చేయండి. యాప్‌లో ఎప్పుడైనా రద్దు చేయవచ్చు.",
    },
    kn: {
      title: "ಯಾವುದೇ ಸ್ಟೇಟಸ್ ಹಂಚಿಕೊಳ್ಳಿ",
      body: "ತಿಂಗಳಿಗೆ ₹99ರ ಪ್ರೀಮಿಯಂನಲ್ಲಿ ಸ್ಟೇಟಸ್ ವೀಡಿಯೊಗಳನ್ನು ಹಂಚಿಕೊಳ್ಳಿ, ಉಳಿಸಿ. ಆ್ಯಪ್‌ನಲ್ಲಿ ಯಾವಾಗ ಬೇಕಾದರೂ ರದ್ದು ಮಾಡಿ.",
    },
    ml: {
      title: "ഏത് സ്റ്റാറ്റസും പങ്കിടൂ",
      body: "പ്രതിമാസം ₹99 പ്രീമിയത്തിൽ സ്റ്റാറ്റസ് വീഡിയോകൾ പങ്കിടാം, സേവ് ചെയ്യാം. ആപ്പിൽ എപ്പോൾ വേണമെങ്കിലും റദ്ദാക്കാം.",
    },
    hi: {
      title: "कोई भी स्टेटस शेयर करें",
      body: "₹99/माह के प्रीमियम से स्टेटस वीडियो शेयर और सेव करें। ऐप में कभी भी रद्द करें।",
    },
  },
];

export function seriesTexts(day: number): Texts {
  return SERIES_MESSAGES[day % SERIES_MESSAGES.length] as Texts;
}

export type SeriesSkip = "no_phone" | "disabled" | "old_build";

/** The revoke push's order, minus what a lapse cannot be: `disabled` after the phone check keeps the baseline honest. */
export function seriesDecision(
  row: { phones: number; newPhones: number },
  live: boolean,
): SeriesSkip | "send" {
  if (row.phones === 0) return "no_phone";
  if (!live) return "disabled";
  if (row.newPhones === 0) return "old_build";
  return "send";
}

/** The automated campaign row's fixed shape -> `dest_id` is what a new build reads to open the ₹99 sheet. */
export const WINBACK_DEST = { dest: "premium", destId: WINBACK_OFFER } as const;
