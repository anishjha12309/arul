/**
 * Upload media constraints (MIME -> max bytes). Sole consumer here: routes/media.ts submission presign.
 *
 * Three copies of these limits exist -> a drift rejects what the client just allowed -> keep all three in step
 * The other two: hsr-cms's media-constraints.ts (which also owns the MIME -> extension map), Flutter's upload_constraints
 */

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
