/**
 * Single source of truth for upload media constraints (MIME → max size).
 * Sole consumer here: routes/media.ts (user submission presign).
 *
 * The operator-authoring and submission-approval consumers moved to the hsr-cms
 * worker on 2026-07-20, taking the MIME → file-extension map with them — see
 * `src/lib/media-constraints.ts` in c:\Anish\Unified CMS. Keep the limits below
 * in sync with that copy AND with the Flutter side
 * (lib/features/upload/.../upload_constraints).
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
