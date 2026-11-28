// THE PICKED PICTURE, MADE INTO THE AVATAR FILE -- in the browser only
// (canvas; it cannot run in the node tests). The rules -- size, crop,
// quality, what counts as a failure -- are lib/avatarImage.ts.
//
// Decoded through an <img>, so whatever the browser can show it can read:
// Safari shows HEIC, and the browser turns the picture upright by its EXIF
// orientation before it is drawn. White underneath, so a transparent PNG
// doesn't turn black in the JPEG. Resolves to the JPEG, or null if the file
// couldn't be decoded or exported.
import { AVATAR_JPEG_QUALITY, AVATAR_OUTPUT_TYPE, AVATAR_SIZE, centreSquare } from "@/lib/avatarImage";

function decode(file: Blob): Promise<HTMLImageElement | null> {
  const url = URL.createObjectURL(file);
  return new Promise((resolve) => {
    const img = new Image();
    const done = (ok: boolean) => {
      URL.revokeObjectURL(url);
      resolve(ok ? img : null);
    };
    img.onload = () => done(true);
    img.onerror = () => done(false);
    img.src = url;
  });
}

export async function convertToAvatarJpeg(file: Blob): Promise<Blob | null> {
  try {
    const img = await decode(file);
    if (!img) return null;
    const square = centreSquare(img.naturalWidth, img.naturalHeight);
    if (!square) return null;
    const canvas = document.createElement("canvas");
    canvas.width = AVATAR_SIZE;
    canvas.height = AVATAR_SIZE;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, AVATAR_SIZE, AVATAR_SIZE);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(img, square.sx, square.sy, square.side, square.side, 0, 0, AVATAR_SIZE, AVATAR_SIZE);
    return await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, AVATAR_OUTPUT_TYPE, AVATAR_JPEG_QUALITY));
  } catch {
    return null;
  }
}
