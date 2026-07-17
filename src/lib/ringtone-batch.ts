/**
 * Arul ringtone batch-upload pairing rules — the canonical (tested) form of the
 * logic the ringtones page's inline uploader script mirrors in browser JS.
 * A batch is N audio files + N cover images matched by filename stem
 * (song1.mp3 ↔ song1.jpg, case-insensitive); every unmatched/invalid file gets
 * its own specific error message; titles derive from the stem (prettified).
 *
 * Keep RT_JS in src/pages/ringtones-arul.tsx in sync with any change here.
 */

/** "Song-one_final.mp3" → "Song-one_final". No extension → the name itself. */
export function stemOf(filename: string): string {
  const i = filename.lastIndexOf(".");
  return i > 0 ? filename.slice(0, i) : filename;
}

/** "song-one_two" → "Song One Two" (dashes/underscores → spaces, title case). */
export function prettifyStem(stem: string): string {
  return stem
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .map((w) => (w.length ? w.charAt(0).toUpperCase() + w.slice(1) : w))
    .join(" ");
}

export interface StemPair {
  audio: string;
  cover: string;
  /** lower-cased matching stem */
  stem: string;
  /** prettified title derived from the audio filename stem */
  title: string;
}

export interface PairResult {
  pairs: StemPair[];
  /** per-file specific error messages for everything that did not pair */
  errors: string[];
}

const AUDIO_EXT = new Set(["mp3", "m4a", "aac"]);
const COVER_EXT = new Set(["jpg", "jpeg"]);

function extOf(filename: string): string {
  const i = filename.lastIndexOf(".");
  return i >= 0 ? filename.slice(i + 1).toLowerCase() : "";
}

/**
 * Pair audio filenames with cover filenames by (case-insensitive) stem.
 * Duplicate stems on either side, wrong extensions, and unmatched files each
 * produce a specific per-file error; only clean 1:1 pairs come back.
 */
export function pairByStem(audioNames: string[], coverNames: string[]): PairResult {
  const errors: string[] = [];
  const pairs: StemPair[] = [];

  const coverByStem = new Map<string, string>();
  const badCoverStems = new Set<string>();
  for (const c of coverNames) {
    if (!COVER_EXT.has(extOf(c))) {
      errors.push(`${c}: covers must be JPEG (.jpg) — 512×512`);
      continue;
    }
    const s = stemOf(c).toLowerCase();
    if (coverByStem.has(s)) {
      badCoverStems.add(s);
      errors.push(`${c}: another cover has the same name stem "${stemOf(c)}"`);
      continue;
    }
    coverByStem.set(s, c);
  }

  const seenAudio = new Set<string>();
  const matchedCoverStems = new Set<string>();
  for (const a of audioNames) {
    if (!AUDIO_EXT.has(extOf(a))) {
      errors.push(`${a}: unsupported audio type — use MP3, M4A or AAC`);
      continue;
    }
    const s = stemOf(a).toLowerCase();
    if (seenAudio.has(s)) {
      errors.push(`${a}: another audio file has the same name stem "${stemOf(a)}"`);
      continue;
    }
    seenAudio.add(s);
    if (badCoverStems.has(s)) {
      // ambiguous covers — refuse to guess which one belongs to this audio
      errors.push(`${a}: skipped — its cover stem "${stemOf(a)}" is ambiguous`);
      continue;
    }
    const cover = coverByStem.get(s);
    if (!cover) {
      errors.push(`${a}: no matching cover image (expected ${stemOf(a)}.jpg)`);
      continue;
    }
    matchedCoverStems.add(s);
    pairs.push({ audio: a, cover, stem: s, title: prettifyStem(stemOf(a)) });
  }

  for (const [s, c] of coverByStem) {
    if (!matchedCoverStems.has(s) && !seenAudio.has(s)) {
      errors.push(`${c}: no matching audio file`);
    }
  }

  return { pairs, errors };
}
