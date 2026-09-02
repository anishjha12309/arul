/**
 * Minimal-but-VALID media byte fixtures for the server-side QC gate (src/lib/media-verify.ts).
 *
 * Each builder emits just enough real structure for the verifier's parsers -> magic bytes, dimensions, an MP4 box tree
 * Every fixture pads to >=64 bytes -> that is the verifier's too-small floor -> a shorter one fails for the wrong reason
 * Not a *.test.ts file -> vitest never runs it directly
 */

// ── Byte assembly helpers ─────────────────────────────────────────────────────

function bytes(...parts: (number[] | Uint8Array | string)[]): Uint8Array {
  const chunks = parts.map((p) =>
    typeof p === "string" ? new TextEncoder().encode(p) : p instanceof Uint8Array ? p : Uint8Array.from(p),
  );
  const total = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.length;
  }
  return out;
}

function u16be(n: number): number[] {
  return [(n >> 8) & 0xff, n & 0xff];
}
function u32be(n: number): number[] {
  return [(n >>> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}
function u24le(n: number): number[] {
  return [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff];
}

function pad(b: Uint8Array, min = 64): Uint8Array {
  if (b.length >= min) return b;
  return bytes(b, new Uint8Array(min - b.length));
}

/** ISO-BMFF box: 4-byte size + fourcc + payload. */
function box(type: string, ...payload: (number[] | Uint8Array | string)[]): Uint8Array {
  const body = bytes(...payload);
  return bytes(u32be(8 + body.length), type, body);
}

// ── Images ────────────────────────────────────────────────────────────────────

export function pngFixture(width = 1080, height = 1920): Uint8Array {
  return pad(
    bytes(
      [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      u32be(13),
      "IHDR",
      u32be(width),
      u32be(height),
      [8, 6, 0, 0, 0], // bit depth, color type, compression, filter, interlace
      u32be(0), // CRC (not validated)
    ),
  );
}

export function jpegFixture(width = 1080, height = 1920): Uint8Array {
  return pad(
    bytes(
      [0xff, 0xd8], // SOI
      [0xff, 0xe0], u16be(16), "JFIF\0", [1, 1, 0], u16be(1), u16be(1), [0, 0], // APP0
      [0xff, 0xc0], u16be(17), [8], u16be(height), u16be(width), [3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1], // SOF0
      [0xff, 0xd9], // EOI
    ),
  );
}

export function webpFixture(width = 1080, height = 1920): Uint8Array {
  // VP8X extended header carries the canvas size -> WebP stores each dimension MINUS ONE
  const vp8x = bytes([0, 0, 0, 0], u24le(width - 1), u24le(height - 1));
  const riffBody = bytes("WEBP", "VP8X", [vp8x.length, 0, 0, 0], vp8x);
  return pad(bytes("RIFF", [riffBody.length & 0xff, (riffBody.length >> 8) & 0xff, 0, 0], riffBody));
}

// ── Audio ─────────────────────────────────────────────────────────────────────

export function mp3Fixture(): Uint8Array {
  return pad(bytes("ID3", [3, 0, 0, 0, 0, 0, 0]));
}

export function aacFixture(): Uint8Array {
  return pad(bytes([0xff, 0xf1, 0x50, 0x80, 0x01, 0xa0, 0xfc]));
}

// ── MP4 / M4A ─────────────────────────────────────────────────────────────────

function mvhd(timescale: number, duration: number): Uint8Array {
  return box(
    "mvhd",
    [0, 0, 0, 0], // version 0 + flags
    u32be(0), // creation
    u32be(0), // modification
    u32be(timescale),
    u32be(duration),
    new Uint8Array(80), // rate/volume/reserved/matrix/pre_defined/next_track
  );
}

function hdlr(handler: "vide" | "soun"): Uint8Array {
  return box("hdlr", [0, 0, 0, 0], u32be(0), handler, new Uint8Array(16));
}

/** VisualSampleEntry (width/height at +32/+34 from the entry start). */
function videoSampleEntry(codec: string, width: number, height: number): Uint8Array {
  return box(
    codec,
    new Uint8Array(6), // reserved
    u16be(1), // data_reference_index
    new Uint8Array(16), // pre_defined / reserved
    u16be(width),
    u16be(height),
    new Uint8Array(46), // resolution, frame_count, compressorname, depth, pre_defined
  );
}

function audioSampleEntry(codec = "mp4a"): Uint8Array {
  return box(codec, new Uint8Array(6), u16be(1), new Uint8Array(20));
}

function trak(handler: "vide" | "soun", sampleEntry: Uint8Array): Uint8Array {
  const stsd = box("stsd", [0, 0, 0, 0], u32be(1), sampleEntry);
  const stbl = box("stbl", stsd);
  const minf = box("minf", stbl);
  const mdia = box("mdia", hdlr(handler), minf);
  return box("trak", mdia);
}

export function mp4Fixture(
  opts: {
    width?: number;
    height?: number;
    codec?: string;
    /** movie duration in seconds (timescale 1000) */
    durationS?: number;
    /** include an audio track alongside the video track */
    withAudio?: boolean;
    /** audio-only container (m4a) — no video track at all */
    audioOnly?: boolean;
    /** Place moov AFTER a large mdat -> the common non-faststart layout the box walk must survive */
    moovAtEnd?: boolean;
  } = {},
): Uint8Array {
  const {
    width = 1024,
    height = 1824,
    codec = "avc1",
    durationS = 10,
    withAudio = false,
    audioOnly = false,
    moovAtEnd = false,
  } = opts;

  const tracks: Uint8Array[] = [];
  if (!audioOnly) tracks.push(trak("vide", videoSampleEntry(codec, width, height)));
  if (withAudio || audioOnly) tracks.push(trak("soun", audioSampleEntry()));

  const ftyp = box("ftyp", "isom", u32be(0x200), "isomiso2avc1mp41");
  const moov = box("moov", mvhd(1000, durationS * 1000), ...tracks);
  const mdat = box("mdat", new Uint8Array(moovAtEnd ? 4096 : 64));

  return moovAtEnd ? bytes(ftyp, mdat, moov) : bytes(ftyp, moov, mdat);
}

// ── Byte-backed R2 mock (QC gate tests) ───────────────────────────────────────

/**
 * An R2 binding whose head/get serve REAL bytes, ranges included -> the media-verify gate runs for real here.
 * It records deletes -> that is what the auto-reject assertions read
 */
export function makeQcR2(
  objects: Record<string, { bytes: Uint8Array; contentType: string }>,
): { bucket: R2Bucket; deletes: string[] } {
  const store = new Map(Object.entries(objects));
  const deletes: string[] = [];
  const bucket = {
    head: async (key: string) => {
      const o = store.get(key);
      return o
        ? { key, size: o.bytes.length, httpMetadata: { contentType: o.contentType } }
        : null;
    },
    get: async (key: string, opts?: { range?: { offset?: number; length?: number } }) => {
      const o = store.get(key);
      if (!o) return null;
      const offset = opts?.range?.offset ?? 0;
      const length = opts?.range?.length ?? o.bytes.length - offset;
      const sliced = o.bytes.subarray(offset, Math.min(o.bytes.length, offset + length));
      return {
        key,
        size: o.bytes.length,
        httpMetadata: { contentType: o.contentType },
        arrayBuffer: async () =>
          sliced.buffer.slice(sliced.byteOffset, sliced.byteOffset + sliced.byteLength),
      };
    },
    delete: async (key: string) => {
      deletes.push(key);
      store.delete(key);
    },
  } as unknown as R2Bucket;
  return { bucket, deletes };
}
