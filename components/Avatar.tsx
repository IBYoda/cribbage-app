// A PLAYER'S AVATAR, everywhere it is drawn: the main menu, Open Tables, the
// opponent chooser, the table's seats and score plates. profiles.avatar_url
// is a full public URL (a Supabase Storage upload), drawn with a plain <img>
// -- next/image would need the storage host configured, for no real gain at
// these sizes. Not every image is square (some are about 3:2), so the image
// is a fixed square, rounded, with object-cover: it crops, never squashes.
// No URL: the first letter of the name in a circle.
//
// tone: "felt" for the card-room pages (a brass ring, a green fill), "table"
// for the game table (a ring in the page background, a grey fill) -- the two
// looks the app already had.
//
// WINGS: tier and wings (the mode, from placementFor in lib/wings.ts) draw a
// player's wings or badge round it (components/Wings.tsx). No tier: exactly the
// avatar, with nothing round it. The Profile's own image uses WingsFrame directly,
// and the Beer Board its SVG (BeerBoard.tsx).

import { WingsFrame } from "@/components/Wings";
import type { WingsMode, WingsTier } from "@/lib/wings";

export type AvatarSize = "xs" | "sm" | "md" | "lg";

const SIZES: Record<AvatarSize, string> = {
  xs: "h-6 w-6 text-[10px]", // 24px: the table's side seats
  sm: "h-7 w-7 text-xs", // 28px: the table's top seat and score plates
  md: "h-12 w-12 text-lg", // 48px: the main menu and Open Tables
  lg: "h-14 w-14 text-xl", // 56px: the opponent chooser
};

const DIAMETERS: Record<AvatarSize, number> = { xs: 24, sm: 28, md: 48, lg: 56 };

const TONES = {
  felt: { ring: "border-2 border-[var(--brass)]", fill: "bg-[#2a6a44]" },
  table: { ring: "border-2 border-background", fill: "bg-zinc-400 text-white dark:bg-zinc-600" },
};

// ringColor: the square table only -- the ring in this player's board-lane
// colour (lib/boardSkins.ts), the same 2px border, with a 1px light hairline
// outside it so a blue or green ring still reads on the blue and green felt.
// It takes no extra room. Unset: the tone's ring, as always.
export function Avatar({
  name,
  url,
  size = "md",
  tone = "felt",
  ringColor,
  tier,
  wings = "none",
}: {
  name: string;
  url: string | null | undefined;
  size?: AvatarSize;
  tone?: keyof typeof TONES;
  ringColor?: string;
  tier?: WingsTier | null;
  wings?: WingsMode;
}) {
  const box = `${SIZES[size]} shrink-0 rounded-full ${TONES[tone].ring}`;
  const ring = ringColor
    ? { borderColor: ringColor, boxShadow: "0 0 0 1px rgba(255, 255, 255, 0.7)" }
    : undefined;
  const avatar = url ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={url} alt="" className={`${box} object-cover`} style={ring} data-lane-ring={ringColor ? "" : undefined} />
  ) : (
    <span
      aria-hidden="true"
      className={`${box} ${TONES[tone].fill} flex items-center justify-center font-bold`}
      style={ring}
      data-lane-ring={ringColor ? "" : undefined}
    >
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
  return (
    <WingsFrame tier={tier} mode={wings} size={DIAMETERS[size]}>
      {avatar}
    </WingsFrame>
  );
}
