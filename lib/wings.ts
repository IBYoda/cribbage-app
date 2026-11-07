// WINGS: earned by beating God, and drawn round the player's avatar. Everything
// about them that isn't React or the server: the tiers, which spot gets what,
// the art's geometry, the once-only milestone and the device settings. Pure, no
// React; tested by scripts/test-phase3.ts. The count comes from get_god_wins()
// (docs/sql/god-wins.sql, read through lib/godWins.ts), and is stored nowhere;
// the drawing is components/Wings.tsx.

export type WingsTier = "white" | "silver" | "gold" | "black";

export const WINGS_TIERS: readonly { tier: WingsTier; wins: number; name: string }[] = [
  { tier: "white", wins: 10, name: "white" },
  { tier: "silver", wins: 25, name: "silver" },
  { tier: "gold", wins: 50, name: "gold" },
  { tier: "black", wins: 100, name: "black" },
];

export function tierForCount(count: number): WingsTier | null {
  let tier: WingsTier | null = null;
  for (const t of WINGS_TIERS) if (count >= t.wins) tier = t.tier;
  return tier;
}

// The next tier up, or null at the top.
export function nextTier(count: number) {
  return WINGS_TIERS.find((t) => count < t.wins) ?? null;
}

// Where a player stands, for the Profile.
export function progress(count: number): { count: number; tier: WingsTier | null; text: string } {
  const next = nextTier(count);
  return {
    count,
    tier: tierForCount(count),
    text: next ? `${count} / ${next.wins} to ${next.name} wings` : "Black wings. Legend.",
  };
}

// The win that makes the count exactly a tier's number.
export function isMilestone(count: number): boolean {
  return WINGS_TIERS.some((t) => t.wins === count);
}

const tierRank = (tier: WingsTier | "none" | null) => WINGS_TIERS.findIndex((t) => t.tier === tier);

// WHICH SPOT GETS WHAT: the one table. full: 2.62 x the avatar, animated.
// mini: `scale` x the avatar, behind it, with a margin of (scale - 1) / 2 x on
// each side (wingsOverhang), only for a player with a tier. badge: a dot on the
// avatar's corner, no extra room. none: never, for anyone. A new avatar spot is
// a new line here.
export type WingsMode = "full" | "mini" | "badge" | "none";
export type WingsPlacement = { mode: WingsMode; scale: number };

export const WINGS_MINI_SCALE = 2;
export const WINGS_FULL_SCALE = 1 / 0.381;

const full: WingsPlacement = { mode: "full", scale: WINGS_FULL_SCALE };
const mini = (scale: number): WingsPlacement => ({ mode: "mini", scale });
const badge: WingsPlacement = { mode: "badge", scale: 1 };
const none: WingsPlacement = { mode: "none", scale: 1 };

export const WINGS_PLACEMENT = {
  profile: full,
  milestone: full,
  // The square table's header, the across player: the name gives way.
  "header-seat": mini(2),
  // The 3- and 4-player side seats' tags: the margin keeps them on screen.
  "side-tag": mini(2),
  // Two plates are 180px wide at 375: room for the margin.
  "plate-2": mini(2),
  // Three are 117px: narrower wings, so a name keeps some letters.
  "plate-3": mini(1.4),
  // Four Solo plates are 87px: tried as mini, a name kept about 1 letter and a
  // score of 121 ran 9px past the plate.
  "plate-4": badge,
  // The two partners' avatars overlap; their wings go behind both, and the
  // margin goes on the pair's outside edges (ScoreStrip).
  "plate-teams": mini(2),
  // Drawn in the board's own SVG, over the mug.
  beer: mini(2),
  // The classic table's seats. Tried as mini: the top band is 32px tall and
  // hides overflow, so 3px of wing tip went; a side column is about 38px wide,
  // and 24px wings need 48.
  "classic-seat": badge,
  "classic-side": badge,
  // The margin keeps the greeting's wings inside the page's own padding.
  "home-greeting": mini(2),
  // Inside the row's padding, so the scroll box never clips them.
  "open-tables": mini(2),
  // The rank and the name move over for them.
  leaderboard: mini(2.2),
  // God and the computers earn nothing.
  "god-chip": none,
  "opponent-chooser": none,
} as const satisfies Record<string, WingsPlacement>;

export type WingsSpot = keyof typeof WINGS_PLACEMENT;

export const placementFor = (spot: WingsSpot): WingsPlacement => WINGS_PLACEMENT[spot];

// The room a winged avatar takes on each side: what its wings hang out by.
export const wingsOverhang = (d: number, scale: number) => ((scale - 1) / 2) * d;

// A score plate's spot, from the row it's in.
export function plateSpot(plateCount: number, memberCount: number): WingsSpot {
  if (memberCount > 1) return "plate-teams";
  if (plateCount >= 4) return "plate-4";
  return plateCount === 3 ? "plate-3" : "plate-2";
}

// THE ART: every image is 1075 x 695 design units, with the avatar's centre
// 475 down, and 410 across in the full art. The space above is for flames.
export const WINGS_ASPECT = 695 / 1075;
export const WINGS_CENTRE_Y = 475 / 695;

// Where the art sits against an avatar of diameter d, from the avatar's own
// top-left. It's `scale` x wider than the avatar, and centred on it.
export function wingsBox(d: number, scale: number) {
  const width = d * scale;
  const height = width * WINGS_ASPECT;
  return { width, height, left: (d - width) / 2, top: d / 2 - height * WINGS_CENTRE_Y };
}

export const wingsUrl = (tier: WingsTier, size: "full" | "mini") => `/wings/${size}-${tier}.webp`;
export const emberUrl = (size: "full" | "mini") => `/wings/${size}-black-ember.webp`;
export const FLAMES_URL = "/wings/black-flames.json";

export function wingsAssets(): string[] {
  return [
    ...WINGS_TIERS.flatMap((t) => [wingsUrl(t.tier, "full"), wingsUrl(t.tier, "mini")]),
    emberUrl("full"),
    emberUrl("mini"),
    FLAMES_URL,
  ];
}

// The badge's colour, and the soft glow behind full wings.
export const WINGS_BADGE: Record<WingsTier, string> = {
  white: "#ffffff",
  silver: "#cfe0ff",
  gold: "#ffd24a",
  black: "#ff5a14",
};
export const WINGS_HALO: Record<WingsTier, string> = {
  white: "rgb(255 246 216 / 0.3)",
  silver: "rgb(207 224 255 / 0.3)",
  gold: "rgb(255 210 74 / 0.3)",
  black: "rgb(255 90 20 / 0.38)",
};

// THE FLAMES ON A PHONE: a touch screen gets every back flame, half the front
// ones and fewer embers. The front list is pairs, an outer flame and its core,
// so whole pairs go. Desktop gets everything.
export const COARSE_EMBERS = 12;

export function flamesForPointer<F, E>(data: { front: F[]; embers: E[] }, coarse: boolean): { front: F[]; embers: E[] } {
  if (!coarse) return { front: data.front, embers: data.embers };
  const count = Math.min(COARSE_EMBERS, data.embers.length);
  return {
    front: data.front.filter((_, i) => Math.floor(i / 2) % 2 === 0),
    // Spread through the list, so they don't bunch in one part of the wings.
    embers: Array.from({ length: count }, (_, i) => data.embers[Math.floor((i * data.embers.length) / count)]),
  };
}

// The badge's size: 11px on the 28px avatar, in step with the rest.
export const badgeSize = (d: number) => Math.round((d * 11) / 28);

// THE MILESTONE SPLASH's words.
export const WINGS_SPLASH: Record<WingsTier, string> = {
  white: "YOU'VE GOT WINGS, MY CHILD",
  silver: "SILVER WINGS, MY CHILD",
  gold: "GOLD WINGS, MY CHILD",
  black: "EVEN GOD FEARS YOU",
};
export const wingsSplashSub = (count: number) => `${count} wins against God`;

// A list of ids as batches of up to 50 (get_god_wins reads no more), no repeats.
export function idBatches(ids: readonly string[], size = 50): string[][] {
  const unique = [...new Set(ids)];
  const batches: string[][] = [];
  for (let i = 0; i < unique.length; i += size) batches.push(unique.slice(i, i + size));
  return batches;
}

// THE SEEN TIER: the highest tier this device has celebrated. "none" is a real
// answer (seen, nothing earned yet), null means never read. Every read and
// write is guarded: storage can be missing or blocked.
export const wingsSeenKey = (userId: string) => `nobs:wings-seen:${userId}`;

export function readSeenTier(userId: string): WingsTier | "none" | null {
  try {
    const stored = localStorage.getItem(wingsSeenKey(userId));
    return stored === "none" || WINGS_TIERS.some((t) => t.tier === stored) ? (stored as WingsTier | "none") : null;
  } catch {
    return null;
  }
}

export function writeSeenTier(userId: string, tier: WingsTier | null) {
  try {
    localStorage.setItem(wingsSeenKey(userId), tier ?? "none");
  } catch {
    // Not remembered: the moment is skipped rather than repeated.
  }
}

// The first time a player's count is read here, their tier is simply noted. That
// is how launch stays silent: anyone already past a threshold just has wings.
export function initSeenTier(userId: string, count: number) {
  if (readSeenTier(userId) === null) writeSeenTier(userId, tierForCount(count));
}

// Whether this count is the moment. Never read (or no storage): no celebration,
// because the moment can't be kept to once.
export function shouldCelebrate(count: number, seen: WingsTier | "none" | null): boolean {
  return seen !== null && isMilestone(count) && tierRank(tierForCount(count)) > tierRank(seen);
}

// THE PROFILE SETTING "Show wings": this device only, on unless turned
// off. Off: nothing at a table or on the lists. A player's own Profile and their
// own milestone still show theirs.
export const WINGS_SETTING_KEY = "nobs:wings";

export function readWingsOn(): boolean {
  try {
    return localStorage.getItem(WINGS_SETTING_KEY) !== "0";
  } catch {
    return true;
  }
}

export function writeWingsOn(on: boolean) {
  try {
    localStorage.setItem(WINGS_SETTING_KEY, on ? "1" : "0");
  } catch {
    // Not saved; the setting stays as it was for next time.
  }
}
