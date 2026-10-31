// PER-PLAYER APPEARANCE: the table surface (and, from stage 2, the card back)
// each player picks for their OWN screen. Purely cosmetic and purely local:
// nothing here reaches the game tables or realtime.
//
// Green Felt is the default -- the same felt as every other screen. The old
// "classic" surface (the plain page) is gone: it is no longer an option, so
// a stored "classic" -- in the database or this device's cached copy -- is
// unknown and reads as Green Felt (normalizeAppearance). The database still
// allows the value; nothing here writes it.

export const TABLE_SURFACES = [
  { id: "black", label: "Black" },
  { id: "green-felt", label: "Green Felt" },
  { id: "blue-felt", label: "Blue Felt" },
  { id: "wood", label: "Wood" },
] as const;

export type TableSurface = (typeof TABLE_SURFACES)[number]["id"];

export const DEFAULT_TABLE_SURFACE: TableSurface = "green-felt";

export function isTableSurface(value: unknown): value is TableSurface {
  return TABLE_SURFACES.some((s) => s.id === value);
}

// Every surface is dark, so the table always takes the dark palette (white
// text, the dark: variants) whatever the device's mode.
export function surfaceIsDark(surface: TableSurface) {
  return isTableSurface(surface);
}

// CARD BACKS: what every face-down card on MY screen looks like. Classic is
// the original red CSS stripes and loads nothing; the others are 5:7 WebP
// art in public/cards/backs/. Painted by app/globals.css ("CARD BACKS") from
// data-back on an ancestor -- the table shell, or the Profile preview.
// "classic" stays the stored id (the database's check constraint lists it);
// only its label changed.
export const CARD_BACKS = [
  { id: "classic", label: "Classic Red" },
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

// ---------------------------------------------------------------------------
// A player's whole appearance, as saved in public.user_appearance
// (docs/sql/appearance-settings.sql, docs/sql/hide-counts.sql). No row means
// the defaults: Green Felt, the Classic Red back, counts shown.
//
// hideCounts: hide the hand and crib COUNT numbers on this player's own
// screen (the recap lines, the count flashes, a count win's breakdown). The
// score strip still moves, and nothing changes for anyone else or on the
// server.
// ---------------------------------------------------------------------------
export type Appearance = { surface: TableSurface; back: CardBack; hideCounts: boolean };

export const DEFAULT_APPEARANCE: Appearance = {
  surface: DEFAULT_TABLE_SURFACE,
  back: DEFAULT_CARD_BACK,
  hideCounts: false,
};

// Anything unknown -- an old value (the removed "classic" surface), a typo,
// a missing row -- is the default. A missing or non-boolean hideCounts (a
// per-device copy cached before the setting existed) is false.
export function normalizeAppearance(value: unknown): Appearance {
  const v = (value ?? {}) as { surface?: unknown; back?: unknown; hideCounts?: unknown };
  return {
    surface: isTableSurface(v.surface) ? v.surface : DEFAULT_TABLE_SURFACE,
    back: isCardBack(v.back) ? v.back : DEFAULT_CARD_BACK,
    hideCounts: v.hideCounts === true,
  };
}

// ---------------------------------------------------------------------------
// THE PER-DEVICE COPY (localStorage), keyed by user id, so a refresh can show
// the right look at once and one account's look never shows for another:
//   LAST_USER_KEY        the user the cached copy belongs to;
//   cacheKey(userId)     that user's { surface, back, hideCounts }.
// Cleared on sign-out and when a different user signs in. Every access is in
// try/catch: with storage blocked, the app simply has no cache.
// The database is the source of truth; this is only a head start.
// ---------------------------------------------------------------------------
const CACHE_PREFIX = "cribbage.appearance.";
const LAST_USER_KEY = `${CACHE_PREFIX}lastUser`;
const cacheKey = (userId: string) => `${CACHE_PREFIX}user.${userId}`;

// This user's cached copy -- only if it IS this user's (the last user on
// this device). Otherwise null.
export function readCachedAppearance(userId: string): Appearance | null {
  try {
    if (localStorage.getItem(LAST_USER_KEY) !== userId) return null;
    const raw = localStorage.getItem(cacheKey(userId));
    return raw ? normalizeAppearance(JSON.parse(raw)) : null;
  } catch {
    return null;
  }
}

// Makes this user the device's last user (dropping anyone else's copy) and
// stores their appearance.
export function writeCachedAppearance(userId: string, appearance: Appearance) {
  try {
    const previous = localStorage.getItem(LAST_USER_KEY);
    if (previous && previous !== userId) localStorage.removeItem(cacheKey(previous));
    localStorage.setItem(LAST_USER_KEY, userId);
    localStorage.setItem(cacheKey(userId), JSON.stringify(appearance));
  } catch {
    // Storage blocked or full: no cache, nothing else changes.
  }
}

// Sign-out: forget the device's last user and their copy.
export function clearCachedAppearance() {
  try {
    const previous = localStorage.getItem(LAST_USER_KEY);
    if (previous) localStorage.removeItem(cacheKey(previous));
    localStorage.removeItem(LAST_USER_KEY);
  } catch {
    // Nothing to clear.
  }
}

// The attribute on <html> that carries this device's cached surface before
// the first paint (set by the inline script below, then kept in step by
// AppearanceProvider). Read ONLY by the table page's Loading screen
// (app/globals.css) -- the table itself takes its look from the provider.
export const HTML_SURFACE_ATTRIBUTE = "data-appearance-surface";

// THE INLINE SCRIPT for app/layout.tsx's <head>. Runs synchronously while the
// HTML is parsed, before the first paint: reads the cached copy for the
// device's last user and, if it holds a known surface, sets the attribute
// above. No cached copy, or one holding the removed "classic" (no longer in
// the list), sets nothing -- and with nothing set the Loading screen is
// Green Felt anyway (app/globals.css), so there is no flash. It can't throw
// (everything is in try/catch) and it only reads storage and sets one
// attribute, so it never blocks the page.
export const APPEARANCE_INLINE_SCRIPT = `(function(){try{var u=localStorage.getItem(${JSON.stringify(
  LAST_USER_KEY
)});if(!u)return;var v=JSON.parse(localStorage.getItem(${JSON.stringify(
  `${CACHE_PREFIX}user.`
)}+u)||"null");if(v&&${JSON.stringify(
  TABLE_SURFACES.map((s) => s.id)
)}.indexOf(v.surface)>=0)document.documentElement.setAttribute(${JSON.stringify(
  HTML_SURFACE_ATTRIBUTE
)},v.surface)}catch(e){}})()`;
