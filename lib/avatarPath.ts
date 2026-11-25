// AVATAR FILE NAMES (step 3 slice E). The avatars bucket's storage policies
// (docs/sql/slice-e-part2.sql) accept exactly "<user id>/avatar.png",
// "avatar.jpg", "avatar.jpeg" or "avatar.webp" -- lower case, nothing else --
// so a picture always overwrites one of at most four files per player. The
// name comes from the picture's type (what the bucket checks), falling back
// to its extension in any case; JPEG is always written as ".jpg". Pure;
// tested by scripts/test-phase3.ts.

export type AvatarExtension = "png" | "jpg" | "webp";

export const AVATAR_TYPE_MESSAGE = "Please choose a PNG, JPEG or WebP picture.";

const BY_TYPE: Record<string, AvatarExtension> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
  "image/webp": "webp",
};

const BY_EXTENSION: Record<string, AvatarExtension> = {
  png: "png",
  jpg: "jpg",
  jpeg: "jpg",
  webp: "webp",
};

// The extension to write, or null for a picture the bucket won't take.
export function avatarExtension(file: { type?: string | null; name?: string | null }): AvatarExtension | null {
  const type = (file.type ?? "").trim().toLowerCase();
  if (type) return BY_TYPE[type] ?? null;
  const name = (file.name ?? "").trim().toLowerCase();
  const dot = name.lastIndexOf(".");
  if (dot < 0) return null;
  return BY_EXTENSION[name.slice(dot + 1)] ?? null;
}

// "<user id>/avatar.<png|jpg|webp>", or null for a picture the bucket won't take.
export function avatarPath(userId: string, file: { type?: string | null; name?: string | null }): string | null {
  const ext = avatarExtension(file);
  return ext ? `${userId}/avatar.${ext}` : null;
}
