// THE PROFILE PICTURE, MADE ON THE PHONE (the iPhone upload fix, 2026-11-28).
// A picked picture is decoded in the browser (Safari decodes HEIC too),
// centre-cropped to a square, scaled to AVATAR_SIZE and exported as a JPEG,
// then uploaded at once as "<user id>/avatar.jpg" (lib/avatarPath.ts) -- one
// small file whatever the phone handed over. The canvas work is
// lib/avatarConvert.ts (browser only); the rules here are pure and tested by
// scripts/test-phase3.ts.

// The picture as saved: AVATAR_SIZE x AVATAR_SIZE, JPEG at this quality.
export const AVATAR_SIZE = 512;
export const AVATAR_JPEG_QUALITY = 0.85;
export const AVATAR_OUTPUT_TYPE = "image/jpeg";

// The avatars bucket's file_size_limit (docs/sql/slice-2-profiles.sql): a
// converted picture over it is refused (it never is in practice: 512 px at
// 0.85 is far smaller).
export const AVATAR_MAX_BYTES = 2 * 1024 * 1024;

// A sanity cap on the PICKED file, before decoding it: a phone photo is
// 2-5 MB; anything past this is not worth decoding on a phone.
export const AVATAR_MAX_INPUT_BYTES = 25 * 1024 * 1024;

// Every line the picture shows, directly under the photo.
export const AVATAR_MESSAGES = {
  saving: "Saving your picture...",
  saved: "Picture saved.",
  unreadable: "That file couldn't be read as a picture. Try a different one.",
  save_failed: "Couldn't save your picture. Check your connection and try again.",
  too_large: "That picture is too large to read. Pick a smaller one.",
} as const;

export type AvatarProblem = "too_large" | "unreadable" | "save_failed";

// The picked file, before decoding: too big to read, empty, or fine (null).
export function pickedFileProblem(size: number): AvatarProblem | null {
  if (!Number.isFinite(size) || size <= 0) return "unreadable";
  if (size > AVATAR_MAX_INPUT_BYTES) return "too_large";
  return null;
}

// The converted JPEG: missing, empty or over the bucket's limit is
// "unreadable" (the picture could not be made into a file we can save).
export function convertedProblem(blob: { size: number } | null | undefined): AvatarProblem | null {
  if (!blob || !Number.isFinite(blob.size) || blob.size <= 0) return "unreadable";
  if (blob.size > AVATAR_MAX_BYTES) return "unreadable";
  return null;
}

// The square to cut from a w x h picture: its centre, as large as the
// shorter side. null for a picture with no size (it didn't decode).
export function centreSquare(width: number, height: number): { sx: number; sy: number; side: number } | null {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return null;
  const side = Math.min(width, height);
  return { sx: Math.floor((width - side) / 2), sy: Math.floor((height - side) / 2), side };
}

// Whether the profile update saved the picture: no error, and exactly one
// row changed (a missing profile row changes none -- that is a failure, not
// a quiet success).
export function avatarUpdateSaved(error: unknown, rows: readonly unknown[] | null | undefined): boolean {
  return !error && Array.isArray(rows) && rows.length === 1;
}
