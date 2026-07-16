/**
 * APP REGISTRY — the single place that maps an app slug to its bindings,
 * endpoints and content-key scheme. Every route module receives an AppDef and
 * reaches its DB / R2 / rebuild endpoint EXCLUSIVELY through it, so an
 * /arul/* mutation is structurally unable to touch a Pakiza binding and vice
 * versa (verified by test/isolation.test.ts).
 *
 * Key schemes (canonical layouts each app's build-catalog expects — copied
 * from the shipped per-app CMSes, not reinvented):
 *   pakiza  wallpaper static → wallpapers/posters/{id}.{jpg|png|webp}
 *           wallpaper live   → wallpapers/full/{id}.mp4
 *           ringtone         → ringtones/audio/{id}.{mp3|m4a|aac}
 *           thumbnail (live) → thumbs/full/<file-stem>.jpg
 *           (no category column anywhere — tags only)
 *   arul    wallpaper        → wallpapers/<category>/{id}.{ext}  (category is
 *           the browse axis AND the key partition; free text, NOT NULL in DB)
 *           thumbnail        → thumbs/<category>/<file-stem>.jpg
 *           (no ringtones table at all)
 *
 * Thumbnails live under a TOP-LEVEL thumbs/ prefix in BOTH buckets on purpose:
 * each app's orphan-sweep cron deletes unreferenced objects under wallpapers/
 * (+ ringtones/ for Pakiza), so a thumbs key nested inside those prefixes would
 * be swept as an orphan (thumb keys are never in the DB — they are derived from
 * full_key via thumbKeyFor). CMS delete/replace flows clean thumbs up instead.
 */

import type { Env } from "./env.js";

export interface AppDef {
  slug: "pakiza" | "arul";
  label: string;
  hyperdrive: (env: Env) => Hyperdrive;
  r2: (env: Env) => R2Bucket;
  /** R2 bucket name — used in S3-API presigned URLs / CopyObject paths. */
  bucketName: string;
  cdnBase: string;
  apiBase: string;
  catalogSecret: (env: Env) => string;
  /** Service binding to the app's Worker (rebuild trigger); undefined in local dev. */
  service: (env: Env) => Fetcher | undefined;
  scopes: readonly string[];
  /** Arul: wallpapers carry a NOT NULL category (browse axis + key partition). */
  hasCategories: boolean;
  /** Pakiza: has the ringtones table + /ringtones authoring pages. */
  hasRingtones: boolean;
  /** Seeded categories offered as datalist suggestions (free text allowed). */
  knownCategories: readonly string[];
  /**
   * Canonical R2 key prefix for an operator wallpaper/ringtone upload, or null
   * when the combination is not allowed for this app.
   */
  keyPrefixFor: (kind: string, contentType: string, category: string | null) => string | null;
  /**
   * Maps a live wallpaper's full_key to its thumbnail R2 key (admin preview +
   * upload-time thumb capture + delete/replace cleanup), or null when the key
   * doesn't fit the scheme.
   * Arul:   wallpapers/<cat>/<stem>.<ext> → thumbs/<cat>/<stem>.jpg
   * Pakiza: wallpapers/full/<stem>.mp4    → thumbs/full/<stem>.jpg
   */
  thumbKeyFor?: (fullKey: string) => string | null;
}

export const PAKIZA: AppDef = {
  slug: "pakiza",
  label: "Pakiza",
  hyperdrive: (env) => env.HYPERDRIVE_PAKIZA,
  r2: (env) => env.R2_PAKIZA,
  bucketName: "pakiza",
  cdnBase: "https://cdn.hsrutility.com",
  apiBase: "https://api.hsrutility.com",
  catalogSecret: (env) => env.PAKIZA_CATALOG_BUILD_SECRET,
  service: (env) => env.PAKIZA_API,
  scopes: ["wallpapers", "ringtones", "submissions", "config"],
  hasCategories: false,
  hasRingtones: true,
  knownCategories: [],
  keyPrefixFor: (kind, contentType) => {
    if (kind === "wallpaper") {
      if (contentType.startsWith("image/")) return "wallpapers/posters";
      if (contentType === "video/mp4") return "wallpapers/full";
      return null;
    }
    if (kind === "ringtone") {
      // Single file per ringtone (no separate preview/full).
      if (!contentType.startsWith("audio/")) return null;
      return "ringtones/audio";
    }
    return null;
  },
  thumbKeyFor: pakizaThumbKey,
};

export const ARUL: AppDef = {
  slug: "arul",
  label: "Arul",
  hyperdrive: (env) => env.HYPERDRIVE_ARUL,
  r2: (env) => env.R2_ARUL,
  bucketName: "south-indian-wallpapers",
  cdnBase: "https://pub-9eeee142ae6e4f109589922622e1d632.r2.dev",
  apiBase: "https://arul-api.twilight-smoke-d495.workers.dev",
  catalogSecret: (env) => env.ARUL_CATALOG_BUILD_SECRET,
  service: (env) => env.ARUL_API,
  scopes: ["wallpapers", "submissions", "config"],
  hasCategories: true,
  hasRingtones: false,
  knownCategories: ["amman", "ayyappan", "murugan", "perumal", "sivan", "temples"],
  keyPrefixFor: (kind, contentType, category) => {
    if (kind !== "wallpaper") return null; // no ringtones anywhere for Arul
    if (!category) return null; // category is REQUIRED — it is the key partition
    if (contentType.startsWith("image/") || contentType === "video/mp4") {
      return `wallpapers/${category}`;
    }
    return null;
  },
  thumbKeyFor: arulThumbKey,
};

export const APPS: readonly AppDef[] = [PAKIZA, ARUL];

export function appBySlug(slug: string): AppDef | null {
  return APPS.find((a) => a.slug === slug) ?? null;
}

/** "wallpapers/<category>/<stem>.<ext>" → "thumbs/<category>/<stem>.jpg" (Arul). */
export function arulThumbKey(fullKey: string): string | null {
  const m = /^wallpapers\/([^/]+)\/([^/]+)$/.exec(fullKey);
  if (!m) return null;
  const stem = m[2]!.replace(/\.[^.]+$/, "");
  return `thumbs/${m[1]}/${stem}.jpg`;
}

/**
 * "wallpapers/full/<stem>.mp4" → "thumbs/full/<stem>.jpg" (Pakiza). Only live
 * videos map — a static wallpaper's poster IS the image, so anything outside
 * wallpapers/full/*.mp4 has no separate thumbnail (null).
 */
export function pakizaThumbKey(fullKey: string): string | null {
  const m = /^wallpapers\/full\/([^/]+)\.mp4$/.exec(fullKey);
  return m ? `thumbs/full/${m[1]}.jpg` : null;
}
