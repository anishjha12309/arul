/**
 * Server-side media QC — the byte-level gate every upload must pass before a
 * DB row can reference it. Reads the object from R2 via the BINDING (ranged
 * GETs of a few KB — Class B ops, no egress) and verifies that the bytes
 * actually are what the signed PUT's Content-Type claims:
 *
 *   images (wallpaper / ringtone cover)
 *     - magic bytes match the stored content-type (JPEG/PNG/WebP)
 *     - dimensions parse from the header and sit inside the per-role bounds
 *   video (live wallpaper, video/mp4)
 *     - ISO-BMFF ftyp present; moov located by a top-level box walk (handles
 *       moov-at-end, 64-bit largesize boxes)
 *     - exactly the hw-decoder-safe geometry the apps need (WALLPAPER_VIDEO
 *       below — the green-edge rule from the submissions preview, now a hard
 *       server gate), H.264 only, and at least one video track
 *   audio (ringtone)
 *     - MP3 / ADTS-AAC magic, or an MP4 (m4a) container whose tracks include
 *       audio and NO video (a renamed video can't ship as a ringtone)
 *
 * There is no "ringtone cover" role. Ringtone row art is GENERATED ON THE
 * CLIENT — the Arul app draws a procedural kolam medallion from the row's id +
 * category (`ringtone_medallion.dart`: "the catalog ships no cover art for
 * ringtones"), and Pakiza does the same — so no cover object is ever uploaded,
 * stored or served, and there is nothing here to verify. The role and its
 * 512×512 rule were removed 2026-08-10 once the CMS stopped authoring covers;
 * nothing in any of the three repos called them.
 *
 * Every check also enforces the real object size against MAX_BYTES_BY_MIME —
 * the presign endpoints only validate the CLAIMED size, so this is the first
 * place the actual byte count is checked.
 *
 * SHARED MODULE: copied verbatim into both app Workers (src/lib/media-verify.ts
 * in c:\Anish\Arul\workers and c:\Anish\Pakiza\workers) the same way
 * media-constraints.ts is — keep all three copies in sync.
 */

import { MAX_BYTES_BY_MIME } from "./media-constraints.js";

// ── Per-role structural rules ─────────────────────────────────────────────────

/**
 * Live-wallpaper geometry (verified on-device 2026-07-06, SD695 + Dimensity
 * 900): software-decode fallback pads buffer width to 128px and Flutter's
 * ImageReader samples the padding as a green edge strip (flutter/flutter
 * #174026); >1088/>1920 exceeds budget hw-decoder caps and forces permanent
 * software decode. Canonical encode is 1024×1824. Mirrors the client-side
 * dimCheck in pages/submissions.tsx — this is the enforcing copy.
 */
export const WALLPAPER_VIDEO = {
  widthMultiple: 128,
  heightMultiple: 32,
  maxShortSide: 1088,
  maxLongSide: 1920,
  /** stsd sample-entry fourccs the budget-device fleet hw-decodes (H.264). */
  allowedCodecs: ["avc1", "avc3"],
} as const;

/** Wallpaper stills: reject icons/thumbnails and decompression-bomb inputs. */
export const WALLPAPER_IMAGE = {
  minShortSide: 480,
  maxSide: 8192,
} as const;

// ── Public API ────────────────────────────────────────────────────────────────

export type MediaRole = "wallpaper" | "ringtone";

export interface VerifyOk {
  ok: true;
  /** Stored (signed-PUT-enforced) content type. */
  contentType: string;
  width?: number;
  height?: number;
  durationMs?: number;
}

export interface VerifyFail {
  ok: false;
  code:
    | "not_found"
    | "bad_type"
    | "too_large"
    | "corrupt"
    | "bad_dimensions"
    | "bad_codec";
  message: string;
}

export type VerifyResult = VerifyOk | VerifyFail;

function fail(code: VerifyFail["code"], message: string): VerifyFail {
  return { ok: false, code, message };
}

/**
 * Verify the object at `key` as `role`. For "wallpaper", static vs live is
 * derived from the stored content-type (image/* vs video/mp4) — the same
 * derivation the approve/publish flows use.
 */
export async function verifyMediaObject(
  bucket: R2Bucket,
  key: string,
  role: MediaRole,
): Promise<VerifyResult> {
  let head: R2Object | null;
  try {
    head = await bucket.head(key);
  } catch {
    return fail("not_found", "Could not read the uploaded file");
  }
  if (!head) return fail("not_found", "Upload not found — complete the upload first");

  const ct = head.httpMetadata?.contentType ?? "";
  const maxBytes = MAX_BYTES_BY_MIME[ct];
  if (maxBytes === undefined) {
    return fail("bad_type", ct ? `File type not allowed: ${ct}` : "The upload has no content type");
  }
  if (head.size > maxBytes) {
    const mb = Math.round(maxBytes / (1024 * 1024));
    return fail("too_large", `File is larger than the ${mb}MB limit for ${ct}`);
  }
  if (head.size < 64) return fail("corrupt", "File is too small to be valid media");

  const reader = new R2Reader(bucket, key, head.size);

  if (role === "wallpaper") {
    if (ct === "video/mp4") return verifyLiveWallpaper(reader, ct);
    if (ct.startsWith("image/")) return verifyWallpaperImage(reader, ct);
    return fail("bad_type", `A wallpaper must be a JPEG/PNG/WebP image or an MP4 video (got "${ct}")`);
  }
  // ringtone
  if (!ct.startsWith("audio/")) {
    return fail("bad_type", `A ringtone must be an audio file (got "${ct}")`);
  }
  return verifyRingtoneAudio(reader, ct);
}

// ── Ranged reader over the R2 binding ─────────────────────────────────────────

const HEAD_CHUNK = 64 * 1024; // one GET covers magic bytes + most image headers
const MAX_MOOV_BYTES = 8 * 1024 * 1024; // sanity cap; a <50MB file's moov is ≪ this
const MAX_JPEG_SCAN = 512 * 1024; // SOF must appear within this prefix

class R2Reader {
  private headChunk: Uint8Array | null = null;

  constructor(
    private bucket: R2Bucket,
    private key: string,
    readonly size: number,
  ) {}

  /** Read [offset, offset+length), clamped to the object; null on R2 failure. */
  async read(offset: number, length: number): Promise<Uint8Array | null> {
    if (offset >= this.size) return new Uint8Array(0);
    const len = Math.min(length, this.size - offset);
    // Serve from the cached head chunk when fully contained (saves Class B ops).
    if (this.headChunk && offset + len <= this.headChunk.length) {
      return this.headChunk.subarray(offset, offset + len);
    }
    try {
      const obj = await this.bucket.get(this.key, { range: { offset, length: len } });
      if (!obj) return null;
      const bytes = new Uint8Array(await obj.arrayBuffer());
      if (offset === 0 && this.headChunk === null) this.headChunk = bytes;
      return bytes;
    } catch {
      return null;
    }
  }

  /** First HEAD_CHUNK bytes (cached). */
  async head(): Promise<Uint8Array | null> {
    if (this.headChunk) return this.headChunk;
    return this.read(0, Math.min(HEAD_CHUNK, this.size));
  }
}

// ── Byte helpers ──────────────────────────────────────────────────────────────

function u16(b: Uint8Array, o: number): number {
  return (b[o]! << 8) | b[o + 1]!;
}
function u32(b: Uint8Array, o: number): number {
  return ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;
}
function u64(b: Uint8Array, o: number): number {
  // JS number is fine: file sizes here are ≤ 50MB.
  return u32(b, o) * 4294967296 + u32(b, o + 4);
}
function fourcc(b: Uint8Array, o: number): string {
  return String.fromCharCode(b[o]!, b[o + 1]!, b[o + 2]!, b[o + 3]!);
}
function startsWith(b: Uint8Array, sig: number[], offset = 0): boolean {
  if (b.length < offset + sig.length) return false;
  for (let i = 0; i < sig.length; i++) if (b[offset + i] !== sig[i]) return false;
  return true;
}

// ── Image sniffing + dimension parsing ────────────────────────────────────────

interface Dims {
  width: number;
  height: number;
}

function sniffImageMime(b: Uint8Array): string | null {
  if (startsWith(b, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (startsWith(b, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (startsWith(b, [0x52, 0x49, 0x46, 0x46]) && b.length >= 12 && fourcc(b, 8) === "WEBP") {
    return "image/webp";
  }
  return null;
}

function parsePngDims(b: Uint8Array): Dims | null {
  // IHDR is REQUIRED to be the first chunk: length@8, "IHDR"@12, w@16, h@20.
  if (b.length < 24 || fourcc(b, 12) !== "IHDR") return null;
  return { width: u32(b, 16), height: u32(b, 20) };
}

async function parseJpegDims(reader: R2Reader): Promise<Dims | null> {
  // Walk markers until a SOFn (baseline/progressive/etc.) frame header.
  let buf = await reader.head();
  if (!buf) return null;
  let o = 2;
  for (let guard = 0; guard < 512; guard++) {
    // Top up the buffer if the walk approaches its end (SOF can sit deep
    // behind large APPn/EXIF segments).
    if (o + 9 > buf.length && buf.length < Math.min(MAX_JPEG_SCAN, reader.size)) {
      const more = await reader.read(0, Math.min(buf.length * 4, MAX_JPEG_SCAN));
      if (!more || more.length <= buf.length) return null;
      buf = more;
    }
    if (o + 4 > buf.length) return null;
    if (buf[o] !== 0xff) return null;
    const marker = buf[o + 1]!;
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) {
      o += 2; // standalone markers have no length field
      continue;
    }
    const segLen = u16(buf, o + 2);
    if (segLen < 2) return null;
    const isSof =
      marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      if (o + 9 > buf.length) return null;
      return { width: u16(buf, o + 7), height: u16(buf, o + 5) };
    }
    if (marker === 0xda) return null; // scan data reached without a SOF
    o += 2 + segLen;
  }
  return null;
}

function parseWebpDims(b: Uint8Array): Dims | null {
  if (b.length < 30) return null;
  const chunk = fourcc(b, 12);
  if (chunk === "VP8X") {
    // 24-bit little-endian canvas size minus one, at offsets 24 / 27.
    const w = 1 + (b[24]! | (b[25]! << 8) | (b[26]! << 16));
    const h = 1 + (b[27]! | (b[28]! << 8) | (b[29]! << 16));
    return { width: w, height: h };
  }
  if (chunk === "VP8 ") {
    // Lossy keyframe: sync 9D 01 2A then 14-bit LE dims.
    if (b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return null;
    return {
      width: (b[26]! | (b[27]! << 8)) & 0x3fff,
      height: (b[28]! | (b[29]! << 8)) & 0x3fff,
    };
  }
  if (chunk === "VP8L") {
    if (b[20] !== 0x2f) return null;
    const bits = b[21]! | (b[22]! << 8) | (b[23]! << 16) | (b[24]! << 24);
    return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >> 14) & 0x3fff) };
  }
  return null;
}

async function readImageDims(reader: R2Reader, ct: string): Promise<Dims | "mismatch" | null> {
  const head = await reader.head();
  if (!head) return null;
  const sniffed = sniffImageMime(head);
  if (sniffed !== ct) return "mismatch";
  if (ct === "image/png") return parsePngDims(head);
  if (ct === "image/webp") return parseWebpDims(head);
  return parseJpegDims(reader);
}

async function verifyWallpaperImage(reader: R2Reader, ct: string): Promise<VerifyResult> {
  const dims = await readImageDims(reader, ct);
  if (dims === "mismatch") {
    return fail("bad_type", `The file's contents are not a valid ${ct.replace("image/", "").toUpperCase()} image`);
  }
  if (!dims) return fail("corrupt", "Could not read the image's dimensions — the file may be corrupt");
  const { width, height } = dims;
  const short = Math.min(width, height);
  const long = Math.max(width, height);
  if (short < WALLPAPER_IMAGE.minShortSide) {
    return fail(
      "bad_dimensions",
      `Image is ${width}×${height} — a wallpaper needs at least ${WALLPAPER_IMAGE.minShortSide}px on its shorter side`,
    );
  }
  if (long > WALLPAPER_IMAGE.maxSide) {
    return fail(
      "bad_dimensions",
      `Image is ${width}×${height} — the largest side must be at most ${WALLPAPER_IMAGE.maxSide}px`,
    );
  }
  return { ok: true, contentType: ct, width, height };
}

// ── MP4 (ISO-BMFF) parsing ────────────────────────────────────────────────────

interface Mp4Info {
  durationMs: number | null;
  videoTracks: { codec: string; width: number; height: number }[];
  audioTracks: number;
}

/**
 * Top-level box walk (ranged 16-byte header reads, so a leading multi-MB mdat
 * is skipped, not fetched) to find ftyp + moov, then a single read of the moov
 * body. Returns null when the file is not a sane MP4.
 */
async function parseMp4(reader: R2Reader): Promise<Mp4Info | null> {
  let offset = 0;
  let sawFtyp = false;
  let moov: Uint8Array | null = null;

  for (let guard = 0; guard < 64 && offset + 8 <= reader.size; guard++) {
    const hdr = await reader.read(offset, 16);
    if (!hdr || hdr.length < 8) return null;
    let boxSize = u32(hdr, 0);
    const type = fourcc(hdr, 4);
    let bodyOffset = offset + 8;
    if (boxSize === 1) {
      if (hdr.length < 16) return null;
      boxSize = u64(hdr, 8);
      bodyOffset = offset + 16;
    } else if (boxSize === 0) {
      boxSize = reader.size - offset; // box extends to EOF
    }
    if (boxSize < 8 || offset + boxSize > reader.size) return null;

    if (type === "ftyp") sawFtyp = true;
    if (type === "moov") {
      const bodyLen = offset + boxSize - bodyOffset;
      if (bodyLen > MAX_MOOV_BYTES) return null;
      moov = await reader.read(bodyOffset, bodyLen);
      if (!moov || moov.length < bodyLen) return null;
    }
    if (sawFtyp && moov) break;
    offset += boxSize;
  }
  if (!sawFtyp || !moov) return null;

  const info: Mp4Info = { durationMs: null, videoTracks: [], audioTracks: 0 };
  walkBoxes(moov, 0, moov.length, (type, body, start, len) => {
    if (type === "mvhd") {
      const version = body[start]!;
      const timescale = version === 1 ? u32(body, start + 20) : u32(body, start + 12);
      const duration = version === 1 ? u64(body, start + 24) : u32(body, start + 16);
      if (timescale > 0) info.durationMs = Math.round((duration / timescale) * 1000);
      return false;
    }
    if (type === "trak") {
      collectTrack(body, start, len, info);
      return false;
    }
    return false; // moov's other children need no descent at this level
  });
  return info;
}

/** Walk sibling boxes in body[start, start+len); cb returns true to descend. */
function walkBoxes(
  body: Uint8Array,
  start: number,
  len: number,
  cb: (type: string, body: Uint8Array, bodyStart: number, bodyLen: number) => boolean,
): void {
  let o = start;
  const end = start + len;
  let guard = 0;
  while (o + 8 <= end && guard++ < 4096) {
    let size = u32(body, o);
    const type = fourcc(body, o + 4);
    let bodyStart = o + 8;
    if (size === 1) {
      if (o + 16 > end) return;
      size = u64(body, o + 8);
      bodyStart = o + 16;
    } else if (size === 0) {
      size = end - o;
    }
    if (size < 8 || o + size > end) return;
    const descend = cb(type, body, bodyStart, o + size - bodyStart);
    if (descend) walkBoxes(body, bodyStart, o + size - bodyStart, cb);
    o += size;
  }
}

/** Extract handler type + (for video) stsd sample-entry codec/dims of one trak. */
function collectTrack(body: Uint8Array, start: number, len: number, info: Mp4Info): void {
  let handler = "";
  let sampleEntry: { codec: string; width: number; height: number } | null = null;

  walkBoxes(body, start, len, (type, b, s, l) => {
    if (type === "mdia" || type === "minf" || type === "stbl") return true;
    if (type === "hdlr") {
      if (l >= 12) handler = fourcc(b, s + 8);
      return false;
    }
    if (type === "stsd") {
      // fullbox(4) + entry_count(4), then sample entries (plain boxes).
      if (l >= 16) {
        const entryStart = s + 8;
        const size = u32(b, entryStart);
        if (size >= 8 && entryStart + size <= s + l) {
          const codec = fourcc(b, entryStart + 4);
          // VisualSampleEntry: width/height u16 at +32/+34 from the entry start.
          if (size >= 36) {
            sampleEntry = {
              codec,
              width: u16(b, entryStart + 32),
              height: u16(b, entryStart + 34),
            };
          } else {
            sampleEntry = { codec, width: 0, height: 0 };
          }
        }
      }
      return false;
    }
    return false;
  });

  if (handler === "soun") info.audioTracks += 1;
  if (handler === "vide" && sampleEntry) info.videoTracks.push(sampleEntry);
}

async function verifyLiveWallpaper(reader: R2Reader, ct: string): Promise<VerifyResult> {
  const mp4 = await parseMp4(reader);
  if (!mp4) return fail("corrupt", "The file's contents are not a valid MP4 video");
  const video = mp4.videoTracks[0];
  if (!video) return fail("corrupt", "The MP4 has no video track — a live wallpaper must be a video");
  const { widthMultiple, heightMultiple, maxShortSide, maxLongSide, allowedCodecs } =
    WALLPAPER_VIDEO;
  if (!(allowedCodecs as readonly string[]).includes(video.codec)) {
    return fail(
      "bad_codec",
      `Video codec "${video.codec}" is not supported — re-encode as H.264 (avc1), canonical 1024×1824`,
    );
  }
  const { width, height } = video;
  if (
    width <= 0 ||
    height <= 0 ||
    width % widthMultiple !== 0 ||
    height % heightMultiple !== 0 ||
    Math.min(width, height) > maxShortSide ||
    Math.max(width, height) > maxLongSide
  ) {
    return fail(
      "bad_dimensions",
      `Video is ${width}×${height} — needs width%${widthMultiple}==0, height%${heightMultiple}==0, ` +
        `within ${maxShortSide}×${maxLongSide} (budget-phone hw decoder cap), else green edge lines / ` +
        `forced software decode. Re-encode to 1024×1824`,
    );
  }
  const result: VerifyOk = { ok: true, contentType: ct, width, height };
  if (mp4.durationMs !== null) result.durationMs = mp4.durationMs;
  return result;
}

// ── Audio ─────────────────────────────────────────────────────────────────────

async function verifyRingtoneAudio(reader: R2Reader, ct: string): Promise<VerifyResult> {
  const head = await reader.head();
  if (!head || head.length < 12) return fail("corrupt", "Could not read the uploaded audio");

  if (ct === "audio/mpeg") {
    const id3 = startsWith(head, [0x49, 0x44, 0x33]); // "ID3"
    const frameSync = head[0] === 0xff && (head[1]! & 0xe0) === 0xe0;
    if (!id3 && !frameSync) return fail("bad_type", "The file's contents are not a valid MP3");
    return { ok: true, contentType: ct };
  }
  if (ct === "audio/aac") {
    const adts = head[0] === 0xff && (head[1]! & 0xf6) === 0xf0;
    const adif = startsWith(head, [0x41, 0x44, 0x49, 0x46]); // "ADIF"
    if (!adts && !adif) return fail("bad_type", "The file's contents are not a valid AAC stream");
    return { ok: true, contentType: ct };
  }
  // audio/mp4 or audio/x-m4a — an MP4 container that must carry audio, not video.
  const mp4 = await parseMp4(reader);
  if (!mp4) return fail("corrupt", "The file's contents are not a valid M4A audio file");
  if (mp4.audioTracks === 0) {
    return fail("bad_type", "The M4A file has no audio track");
  }
  if (mp4.videoTracks.length > 0) {
    return fail("bad_type", "The file contains video — a ringtone must be audio only");
  }
  const result: VerifyOk = { ok: true, contentType: ct };
  if (mp4.durationMs !== null) result.durationMs = mp4.durationMs;
  return result;
}
