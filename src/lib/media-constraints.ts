/**
 * Single source of truth for upload media constraints (MIME → max size, MIME →
 * file extension). Copied verbatim from the app Workers so operator uploads
 * accept exactly what each app's build-catalog can serve.
 */

/** Allowed upload MIME types → max bytes. */
export const MAX_BYTES_BY_MIME: Record<string, number> = {
  "image/jpeg": 10 * 1024 * 1024,
  "image/png": 10 * 1024 * 1024,
  "image/webp": 10 * 1024 * 1024,
  "video/mp4": 50 * 1024 * 1024,
  "audio/mpeg": 15 * 1024 * 1024,
  "audio/aac": 15 * 1024 * 1024,
  "audio/mp4": 15 * 1024 * 1024,
  "audio/x-m4a": 15 * 1024 * 1024,
};

/** Canonical file extension for an allowed MIME type. */
export const EXT_BY_MIME: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "video/mp4": "mp4",
  "audio/mpeg": "mp3",
  "audio/aac": "aac",
  "audio/mp4": "m4a",
  "audio/x-m4a": "m4a",
};
