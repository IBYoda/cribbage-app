// PER-PLAYER APPEARANCE: the table surface (and, from stage 2, the card back)
// each player picks for their OWN screen. Purely cosmetic and purely local:
// nothing here reaches the game tables or realtime.
//
// "classic" is the default and looks exactly like the app did before this
// feature: the page's own light/dark background, following the device.

export const TABLE_SURFACES = [
  { id: "classic", label: "Classic (current)" },
  { id: "black", label: "Black" },
  { id: "green-felt", label: "Green Felt" },
  { id: "blue-felt", label: "Blue Felt" },
  { id: "wood", label: "Wood" },
] as const;

export type TableSurface = (typeof TABLE_SURFACES)[number]["id"];

export const DEFAULT_TABLE_SURFACE: TableSurface = "classic";

export function isTableSurface(value: unknown): value is TableSurface {
  return TABLE_SURFACES.some((s) => s.id === value);
}

// Every surface except Classic is dark, so the table forces the dark palette
// on it (white text, the dark: variants) whatever the device's mode. Classic
// keeps following the device, exactly as before.
export function surfaceIsDark(surface: TableSurface) {
  return surface !== "classic";
}

// CARD BACKS: what every face-down card on MY screen looks like. Classic is
// the original red CSS stripes and loads nothing; the others are 5:7 WebP
// art in public/cards/backs/. Painted by app/globals.css ("CARD BACKS") from
// data-back on an ancestor -- the table shell, or the Profile preview.
export const CARD_BACKS = [
  { id: "classic", label: "Classic (current)" },
  { id: "metallic-black", label: "Modern Metallic Black" },
  { id: "vintage", label: "Vintage" },
  { id: "oktoberfish", label: "Oktoberfish" },
  { id: "plain-black", label: "Plain Black" },
  { id: "standard-red", label: "Standard Red" },
  { id: "standard-blue", label: "Standard Blue" },
] as const;

export type CardBack = (typeof CARD_BACKS)[number]["id"];

export const DEFAULT_CARD_BACK: CardBack = "classic";

export function isCardBack(value: unknown): value is CardBack {
  return CARD_BACKS.some((b) => b.id === value);
}

// The art's URL, or null for Classic (CSS only). For preloading the chosen
// back; the stylesheet holds the same paths.
export function cardBackUrl(back: CardBack) {
  return back === "classic" ? null : `/cards/backs/${back}.webp`;
}
