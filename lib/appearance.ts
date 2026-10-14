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
