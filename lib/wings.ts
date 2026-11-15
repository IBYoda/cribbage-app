// WINGS: earned by beating God, and drawn round the player's avatar. Everything
// about them that isn't React or the server: the tiers, which spot gets what,
// the art's geometry, the once-only milestone and the device settings. Pure, no
// React; tested by scripts/test-phase3.ts. The count comes from get_god_wins()
// (docs/sql/god-wins.sql, read through lib/godWins.ts), and is stored nowhere;
// the drawing is components/Wings.tsx.

// The tiers a God-win count earns, and what a player's wings show: one of
// those, or the creator's own (displayTier).
export type GodWinsTier =
  | "white"
  | "bronze"
  | "silver"
  | "gold"
  | "emerald"
  | "sapphire"
  | "ruby"
  | "diamond"
  | "prismatic"
  | "black";
export type WingsTier = GodWinsTier | "creator";

// THE LADDER: one tier every 10 God wins, lowest first. The one table: every
// threshold, name and milestone comes from here. (Until Nov 2026 it was four
// tiers: white 10, silver 25, gold 50, black 100.)
export const WINGS_TIERS: readonly { tier: GodWinsTier; wins: number; name: string }[] = [
  { tier: "white", wins: 10, name: "white" },
  { tier: "bronze", wins: 20, name: "bronze" },
  { tier: "silver", wins: 30, name: "silver" },
  { tier: "gold", wins: 40, name: "gold" },
  { tier: "emerald", wins: 50, name: "emerald" },
  { tier: "sapphire", wins: 60, name: "sapphire" },
  { tier: "ruby", wins: 70, name: "ruby" },
  { tier: "diamond", wins: 80, name: "diamond" },
  { tier: "prismatic", wins: 90, name: "prismatic" },
  { tier: "black", wins: 100, name: "black" },
];

export function tierForCount(count: number): GodWinsTier | null {
  let tier: GodWinsTier | null = null;
  for (const t of WINGS_TIERS) if (count >= t.wins) tier = t.tier;
  return tier;
}

// THE CREATOR'S EARS: a pair of green ears (Walt's own art, docs/wings-art.md)
// in place of wings, with no flames, for the account(s) here and nobody else.
// They are the "creator" tier: they win over any God-win tier and need no
// database, so they show even when get_god_wins can't be read. Only the
// display changes: the creator's real God wins still drive the milestone and
// the seen tier.
export const CREATOR_USER_IDS: readonly string[] = ["f190b27b-a23b-4464-8445-023edbee28b2"];

export const isCreator = (userId: string | null | undefined) => !!userId && CREATOR_USER_IDS.includes(userId);

// What a player's wings show: the creator's, else what their count earned.
// Every place that turns a player into wings asks this first.
export function displayTier(userId: string | null | undefined, earned: GodWinsTier | null | undefined): WingsTier | null {
  return isCreator(userId) ? "creator" : (earned ?? null);
}

// Tiers drawn burning: the black tier's flames, embers and glow. Black only:
// the creator's ears don't burn.
export const hasFlames = (tier: WingsTier) => tier === "black";

// The next tier up, or null at the top.
export function nextTier(count: number) {
  return WINGS_TIERS.find((t) => count < t.wins) ?? null;
}

// Where a player stands, for the Profile. At the top: the top tier's name.
const TOP_TIER = WINGS_TIERS[WINGS_TIERS.length - 1];
const capitalised = (name: string) => name.charAt(0).toUpperCase() + name.slice(1);

export function progress(count: number): { count: number; tier: GodWinsTier | null; text: string } {
  const next = nextTier(count);
  return {
    count,
    tier: tierForCount(count),
    text: next ? `${count} / ${next.wins} to ${next.name} wings` : `${capitalised(TOP_TIER.name)} wings. Legend.`,
  };
}

// The win that makes the count exactly a tier's number.
export function isMilestone(count: number): boolean {
  return WINGS_TIERS.some((t) => t.wins === count);
}

const tierRank = (tier: GodWinsTier | "none" | null) => WINGS_TIERS.findIndex((t) => t.tier === tier);

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

// Each tier's art, by file name. The creator's is the ears (full-ears.webp,
// mini-ears.webp), on the same canvas and anchors as the wings. Emerald comes
// from the old creator's green wings (removed in PR #107), without flames.
// Bronze, sapphire, ruby, diamond and prismatic are made from silver's art, and
// silver, gold and emerald remade from their own originals, by
// scripts/make-wings-tiers.mjs (sources in docs/art/sources; docs/wings-art.md).
const WINGS_ART: Record<WingsTier, string> = {
  white: "white",
  bronze: "bronze",
  silver: "silver",
  gold: "gold",
  emerald: "emerald",
  sapphire: "sapphire",
  ruby: "ruby",
  diamond: "diamond",
  prismatic: "prismatic",
  black: "black",
  creator: "ears",
};
export const ALL_WINGS_TIERS: readonly WingsTier[] = [...WINGS_TIERS.map((t) => t.tier), "creator"];

// No version in the URL, on purpose: public/ files are served with
// "Cache-Control: public, max-age=0, must-revalidate" and an ETag of the file's
// hash (checked on the live site, Nov 15, 2026; next.config.ts sets no headers
// and there is no service worker), so a browser re-checks each image and a
// changed file under the same name reaches every player on their next load.
// If a long or immutable cache is ever added for /wings, add a version here.
export const wingsUrl = (tier: WingsTier, size: "full" | "mini") => `/wings/${size}-${WINGS_ART[tier]}.webp`;
export const emberUrl = (size: "full" | "mini") => `/wings/${size}-black-ember.webp`;
export const FLAMES_URL = "/wings/black-flames.json";

export function wingsAssets(): string[] {
  return [
    ...ALL_WINGS_TIERS.flatMap((tier) => [wingsUrl(tier, "full"), wingsUrl(tier, "mini")]),
    emberUrl("full"),
    emberUrl("mini"),
    FLAMES_URL,
  ];
}

// The badge's colour, as a CSS background (so a gradient works), and the soft
// glow behind full wings: none for the ears. The badge is an 11px dot with a
// dark edge, so white, silver (pale blue) and diamond (white into ice blue)
// must stay apart there. The creator keeps its bright green dot; emerald's is
// a deeper green.
export const WINGS_BADGE: Record<WingsTier, string> = {
  white: "#ffffff",
  bronze: "#b8733a",
  silver: "#cfe0ff",
  gold: "#ffd24a",
  emerald: "#0f9d58",
  sapphire: "#2f5fe8",
  ruby: "#d4143c",
  diamond: "linear-gradient(135deg, #ffffff 0%, #ffffff 30%, #8fe3ff 65%, #3fb4e6 100%)",
  prismatic: "conic-gradient(#ff4d4d, #ffb84d, #f5e94d, #4ddc6a, #4dc3ff, #6a5cff, #d04dff, #ff4d4d)",
  black: "#ff5a14",
  creator: "#2ee07a",
};
export const WINGS_HALO: Record<WingsTier, string | null> = {
  white: "rgb(255 246 216 / 0.3)",
  bronze: "rgb(205 127 50 / 0.3)",
  silver: "rgb(207 224 255 / 0.3)",
  gold: "rgb(255 210 74 / 0.3)",
  emerald: "rgb(46 200 120 / 0.28)",
  sapphire: "rgb(80 130 255 / 0.3)",
  ruby: "rgb(230 40 80 / 0.28)",
  diamond: "rgb(190 236 255 / 0.32)",
  prismatic: "rgb(215 175 255 / 0.3)",
  black: "rgb(255 90 20 / 0.38)",
  creator: null,
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

// THE MILESTONE SPLASH's words. The creator has no splash.
export const WINGS_SPLASH: Record<GodWinsTier, string> = {
  white: "YOU'VE GOT WINGS, MY CHILD",
  bronze: "BRONZE WINGS, MY CHILD",
  silver: "SILVER WINGS, MY CHILD",
  gold: "GOLD WINGS, MY CHILD",
  emerald: "EMERALD WINGS, MY CHILD",
  sapphire: "SAPPHIRE WINGS, MY CHILD",
  ruby: "RUBY WINGS, MY CHILD",
  diamond: "DIAMOND WINGS, MY CHILD",
  prismatic: "PRISMATIC WINGS, MY CHILD",
  black: "EVEN GOD FEARS YOU",
};
export const wingsSplashSub = (count: number) => `${count} ${count === 1 ? "win" : "wins"} against God`;

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
//
// v2 since the ten-tier ladder. The old key (nobs:wings-seen:<user>) held a
// tier of the four-tier ladder, whose rank no longer matches the counts: an old
// "silver" at 27 wins would have hidden the silver splash at 30. It is simply
// no longer read.
export const wingsSeenKey = (userId: string) => `nobs:wings-seen:v2:${userId}`;

export function readSeenTier(userId: string): GodWinsTier | "none" | null {
  try {
    const stored = localStorage.getItem(wingsSeenKey(userId));
    return stored === "none" || WINGS_TIERS.some((t) => t.tier === stored) ? (stored as GodWinsTier | "none") : null;
  } catch {
    return null;
  }
}

export function writeSeenTier(userId: string, tier: GodWinsTier | null) {
  try {
    localStorage.setItem(wingsSeenKey(userId), tier ?? "none");
  } catch {
    // Not remembered: the moment is skipped rather than repeated.
  }
}

// The milestones the ten-tier ladder brought: every threshold but white's 10
// and black's 100, which the four-tier ladder already had at the same count.
const FOUR_TIER_MILESTONES: readonly number[] = [10, 100];

export function isNewLadderMilestone(count: number): boolean {
  return isMilestone(count) && !FOUR_TIER_MILESTONES.includes(count);
}

// The first time a player's count is read here, their tier is simply noted. That
// is how launch stays silent: anyone already past a threshold just has wings.
// One exception, for the ten-tier ladder: a count of exactly one of its new
// milestones (20, 30 ... 90) notes the tier below, so that splash, which the
// old ladder never gave, still shows once: when the won game's result is next
// on screen, or at once if this read is the win's own (the table page).
export function initSeenTier(userId: string, count: number) {
  if (readSeenTier(userId) !== null) return;
  writeSeenTier(userId, tierForCount(isNewLadderMilestone(count) ? count - 1 : count));
}

// Whether this count is the moment. Never read (or no storage): no celebration,
// because the moment can't be kept to once.
export function shouldCelebrate(count: number, seen: GodWinsTier | "none" | null): boolean {
  return seen !== null && isMilestone(count) && tierRank(tierForCount(count)) > tierRank(seen);
}

// CLAIMING THE MOMENT, for whoever shows it (the table page, Home): notes a
// first read, asks, and writes the seen tier before anything shows, so the
// moment is claimed once on this device, wherever it is shown first. The tier
// to show, or null. The creator's seen tier moves as anyone's, but the ears
// always show as the creator's: no splash for a tier they never see. Hidden
// and test accounts never get here with a count: get_god_wins leaves them out.
export function claimWingsMoment(userId: string, count: number): GodWinsTier | null {
  initSeenTier(userId, count);
  const tier = tierForCount(count);
  if (!tier || !shouldCelebrate(count, readSeenTier(userId))) return null;
  writeSeenTier(userId, tier);
  return isCreator(userId) ? null : tier;
}

// HOME'S CATCH-UP: only for a count of exactly one of the ten-tier ladder's
// new milestones (20, 30 ... 90), the splash the old ladder never gave. The
// table's result screen is the other catch-up, but only while the won game is
// still the table's latest; this one needs nothing but the count. Every other
// count, white's 10 and black's 100 included, is the table's alone.
export function claimHomeWingsMoment(userId: string, count: number): GodWinsTier | null {
  if (!isNewLadderMilestone(count)) {
    initSeenTier(userId, count);
    return null;
  }
  return claimWingsMoment(userId, count);
}

// THE SETTINGS PAGE'S "Show wings": this device only, on unless turned
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
