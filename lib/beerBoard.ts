// THE BEER BOARD (lib/customBoards.ts): each mug of beer is a score, and it
// drains as the score rises. Pure, no React, no browser APIs. Tested by
// scripts/test-phase3.ts. Drawn by components/table/BeerBoard.tsx.
//
// This board replaces the score plates as well as the board, so it reads the
// plates themselves (the lane-coloured ScorePlate[] the table page builds):
// their order (me first), their grouping, their avatars and their scoreHidden.
// A number on a mug is always the plate's, never BoardPlayer.score.
//
// Two coordinate spaces. The art's layers are all 340px tall and each mug's
// measurements (BEER_MUGS, from public/boards/beer/beer-layers.json) are in
// those layer px; beerDrawing and beerFoamCap work there. beerScene turns the
// strip's real size into px positions for the mugs, the numbers and the
// avatars.

import type { ScorePlate } from "@/components/table/ScoreStrip";
import type { WingsTier } from "@/lib/wings";
import { GAME_HOLE, clampScore } from "@/lib/boardLayout";
import { laneRingColor, type BoardSkin } from "@/lib/boardSkins";
import type { CustomBoard } from "@/lib/customBoards";

export const BEER_LAYER_HEIGHT = 340;

// Every mug's measurements, in layer px. Checked against the json on disk by
// scripts/test-phase3.ts, so the two can't drift apart. One deliberate
// difference: 4-3's glass. The json has it at 51.32 .. 238.07, but those were
// caught on a foam drip and on the handle; the layer's own pixels put the glass
// at about 15 .. 208, as on its three siblings, and with the json's numbers the
// foam cap sits out over the handle for the mug's whole drain.
export type BeerMugArt = {
  w: number;
  h: number;
  rim: number;
  // The beer's top (full) and bottom (empty), and the glass's sides.
  bt: number;
  bb: number;
  glassX0: number;
  glassX1: number;
  // The rows the band image was cut from (it is already cropped to them).
  bandTop: number;
  bandBottom: number;
  crownBottom: number;
};

const THREE: Pick<BeerMugArt, "h" | "rim" | "bt" | "bb" | "bandTop" | "bandBottom" | "crownBottom"> = {
  h: 340,
  rim: 67.01,
  bt: 109.85,
  bb: 290.02,
  bandTop: 67.01,
  bandBottom: 110.95,
  crownBottom: 65.91,
};
const FOUR: typeof THREE = {
  h: 340,
  rim: 67.71,
  bt: 112.62,
  bb: 292.24,
  bandTop: 67.71,
  bandBottom: 114.05,
  crownBottom: 66.29,
};

export const BEER_MUGS = {
  "3-0": { ...THREE, w: 271, glassX0: 16.48, glassX1: 201.03 },
  "3-1": { ...THREE, w: 272, glassX0: 18.68, glassX1: 201.58 },
  "3-2": { ...THREE, w: 258, glassX0: 18.13, glassX1: 197.19 },
  "4-0": { ...FOUR, w: 267, glassX0: 11.4, glassX1: 206.71 },
  "4-1": { ...FOUR, w: 267, glassX0: 11.4, glassX1: 205.28 },
  "4-2": { ...FOUR, w: 267, glassX0: 12.83, glassX1: 206.0 },
  "4-3": { ...FOUR, w: 266, glassX0: 12, glassX1: 205.5 },
} as const satisfies Record<string, BeerMugArt>;

export type BeerMugId = keyof typeof BEER_MUGS;

export type BeerLayer = "base" | "cover" | "beer" | "band" | "crown";
export const BEER_LAYERS: readonly BeerLayer[] = ["base", "cover", "beer", "band", "crown"];

export function beerLayerUrl(id: BeerMugId, layer: BeerLayer): string {
  return `/boards/beer/${id}-${layer}.webp`;
}

// The "3-*" mugs are for 3-player games only; everything else uses the "4-*".
export function beerMugIdsFor(playerCount: number): BeerMugId[] {
  return playerCount === 3 ? ["3-0", "3-1", "3-2"] : ["4-0", "4-1", "4-2", "4-3"];
}

// Every layer a game of this size draws, for the table's preload.
export function beerLayerUrls(playerCount: number): string[] {
  return beerMugIdsFor(playerCount).flatMap((id) => BEER_LAYERS.map((layer) => beerLayerUrl(id, layer)));
}

// WHETHER THE PLATES GO: only a board that says so, and never on a
// Self-Scoring (Muggins) table, whose plates are the win controls and which
// shows the banner instead of any board.
export function platesReplaced(board: CustomBoard | null | undefined, isMuggins: boolean): boolean {
  return !!board && "replacesPlates" in board && board.replacesPlates && !isMuggins;
}

const clamp = (n: number, lo: number, hi: number) => Math.min(Math.max(n, lo), hi);
const round = (n: number) => Math.round(n * 100) / 100;

// A MUG'S LEVEL for a score: 1 is full, 0 is empty. A mug covers the points
// from lo to hi.
export function beerLevel(score: number, lo: number, hi: number): number {
  return 1 - clamp((score - lo) / (hi - lo), 0, 1);
}

// Two mugs each: the first is empty at the turn, the second at the game hole.
export const BEER_PAIR_TURN = 60;

// WHICH LAYOUT, from the plates' shape:
//   three: 3 players, one mug each;
//   four: 4-player Solo, one mug each;
//   pairs: 2 players, two mugs each, score and avatar across the pair;
//   teams: 4-player Teams, two mugs a team, the score across the pair and
//     each teammate's avatar on their own mug.
export type BeerLayout = "three" | "four" | "pairs" | "teams";

export function beerLayoutFor(plates: readonly Pick<ScorePlate, "members">[]): BeerLayout {
  if (plates.length === 3) return "three";
  if (plates.length === 4) return "four";
  return plates.some((p) => p.members.length > 1) ? "teams" : "pairs";
}

// One mug in a layout: which art, which plate it belongs to, and the points it
// covers. member: which of the plate's members has their avatar on this mug
// (null: the avatar isn't on a mug, it's across the pair).
export type BeerSlot = { id: BeerMugId; plate: number; member: number | null; lo: number; hi: number };

export function beerSlots(layout: BeerLayout): BeerSlot[] {
  if (layout === "three" || layout === "four") {
    return beerMugIdsFor(layout === "three" ? 3 : 4).map((id, plate) => ({ id, plate, member: 0, lo: 0, hi: GAME_HOLE }));
  }
  const teams = layout === "teams";
  return beerMugIdsFor(4).map((id, i) => {
    const second = i % 2 === 1;
    return {
      id,
      plate: i < 2 ? 0 : 1,
      member: teams ? (second ? 1 : 0) : null,
      lo: second ? BEER_PAIR_TURN : 0,
      hi: second ? GAME_HOLE : BEER_PAIR_TURN,
    };
  });
}

// WHAT THE STRIP SHOWS, in px.
export type BeerSceneMug = BeerSlot & {
  art: BeerMugArt;
  // The mug's top-left and its layer px to px.
  x: number;
  y: number;
  scale: number;
  // The plate's score (null: hidden, a rejoined seat) and the mug's level.
  score: number | null;
  level: number;
};
export type BeerSceneScore = { key: string; text: string; x: number; y: number; fontSize: number };
export type BeerSceneAvatar = {
  key: string;
  x: number;
  y: number;
  r: number;
  name: string;
  letter: string;
  url: string | null;
  ringColor: string;
  // This is me: the gold ring.
  mine: boolean;
  // Their wings. Only a player with a tier carries the key.
  wings?: WingsTier;
};
export type BeerScene = { layout: BeerLayout; mugs: BeerSceneMug[]; scores: BeerSceneScore[]; avatars: BeerSceneAvatar[] };

// The mug's proportions on the strip: 0.9 of its height, standing at 0.935 of
// it, nudged left (the handle makes the glass look off-centre).
const MUG_HEIGHT = 0.9;
const MUG_FOOT = 0.935;
const MUG_NUDGE = 0.04;
const PAIR_GAP = 0.05;
// On a tall strip at a phone's width, four mugs are nearly as wide as the strip
// and the nudge pushes the first off its left edge. Its glass stops this many px
// inside instead (only the art's clear margin goes past the edge).
const GLASS_MARGIN = 2;
// In layer px, from a mug's top. One mug: the number, then the avatar.
const SCORE_Y = 172;
const AVATAR_Y = 272;
const AVATAR_R = 45;
const FONT = { two: 83, three: 71 };
// Across a pair.
const PAIR_AVATAR_R = 47;
const PAIR_SCORE_Y = SCORE_Y - 0.05 * PAIR_AVATAR_R;
const PAIR_AVATAR_Y = AVATAR_Y + 0.15 * PAIR_AVATAR_R;
const PAIR_FONT = { two: 95, three: 82 };
// A ring for a plate with no lane colour.
const NO_LANE_RING = "#d6d3d1";

function beerAvatar(
  key: string,
  member: ScorePlate["members"][number],
  plate: ScorePlate,
  mine: boolean,
  at: { x: number; y: number; r: number }
): BeerSceneAvatar {
  return {
    key,
    ...at,
    name: member.name,
    letter: member.name.slice(0, 1).toUpperCase(),
    url: member.avatarUrl,
    ringColor: plate.laneColor ?? NO_LANE_RING,
    mine,
    ...(member.wings ? { wings: member.wings } : {}),
  };
}

// THE STRIP, for its real size and the plates. A plate whose score is hidden
// (a rejoined seat) keeps its avatar, shows no number, and its mug stays full.
export function beerScene(width: number, height: number, plates: readonly ScorePlate[]): BeerScene {
  const layout = beerLayoutFor(plates);
  const scale = (height * MUG_HEIGHT) / BEER_LAYER_HEIGHT;
  const top = height * MUG_FOOT - height * MUG_HEIGHT;
  const nudge = height * MUG_NUDGE;
  const pairs = layout === "pairs" || layout === "teams";
  const count = layout === "three" ? 3 : 4;

  // A mug's centre before the nudge: evenly spaced, or either side of its pair.
  const centreOf = (index: number, plate: number, artWidth: number) => {
    if (!pairs) return (width * (2 * index + 1)) / (2 * count);
    const pair = plate === 0 ? 0.25 : 0.75;
    const apart = artWidth * scale + height * PAIR_GAP;
    return width * pair + (index % 2 === 0 ? -0.5 : 0.5) * apart;
  };

  const mugs = beerSlots(layout).flatMap((slot, index): BeerSceneMug[] => {
    const plate = plates[slot.plate];
    if (!plate) return [];
    const art = BEER_MUGS[slot.id];
    const score = plate.scoreHidden ? null : plate.score;
    return [
      {
        ...slot,
        art,
        x: Math.max(centreOf(index, slot.plate, art.w) - (art.w * scale) / 2 - nudge, GLASS_MARGIN - art.glassX0 * scale),
        y: top,
        scale,
        score,
        level: score === null ? 1 : beerLevel(score, slot.lo, slot.hi),
      },
    ];
  });

  const scores: BeerSceneScore[] = [];
  const avatars: BeerSceneAvatar[] = [];
  plates.slice(0, count).forEach((plate, i) => {
    const text = plate.scoreHidden ? null : String(plate.score);
    const font = text !== null && text.length >= 3 ? "three" : "two";
    if (pairs) {
      // The middle of the pair as drawn: the mugs are both nudged.
      const x = width * (i === 0 ? 0.25 : 0.75) - nudge;
      if (text !== null) {
        scores.push({ key: plate.key, text, x, y: top + PAIR_SCORE_Y * scale, fontSize: PAIR_FONT[font] * scale });
      }
      if (layout === "pairs") {
        const member = plate.members[0];
        if (member) {
          avatars.push(
            beerAvatar(plate.key, member, plate, plate.isMine, { x, y: top + PAIR_AVATAR_Y * scale, r: PAIR_AVATAR_R * scale })
          );
        }
      }
      return;
    }
    const mug = mugs.find((m) => m.plate === i);
    if (!mug) return;
    const x = mug.x + (mug.art.w * scale) / 2;
    if (text !== null) scores.push({ key: plate.key, text, x, y: top + SCORE_Y * scale, fontSize: FONT[font] * scale });
    const member = plate.members[0];
    if (member) {
      avatars.push(beerAvatar(plate.key, member, plate, plate.isMine, { x, y: top + AVATAR_Y * scale, r: AVATAR_R * scale }));
    }
  });
  // Teams: each teammate on their own mug. buildPlates puts me first on my
  // plate, so on my team the first mug's avatar is the one that's me.
  if (layout === "teams") {
    for (const mug of mugs) {
      const plate = plates[mug.plate];
      const member = mug.member === null ? undefined : plate.members[mug.member];
      if (!member) continue;
      avatars.push(
        beerAvatar(`${mug.id} ${member.userId}`, member, plate, plate.isMine && mug.member === 0, {
          x: mug.x + (mug.art.w * scale) / 2,
          y: top + AVATAR_Y * scale,
          r: AVATAR_R * scale,
        })
      );
    }
  }
  return { layout, mugs, scores, avatars };
}

// THE DRAIN. Every value is in the mug's layer px.
const CAP_MAX_LEVEL = 0.985;
const CAP_DEPTH = 8;
const CREAM = "#f4e8cc";
export const BEER_FOAM_COLOR = CREAM;

function beerRandom(seed: number): () => number {
  let s = seed | 0;
  return () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// The level of the beer's surface. L <= 0: below the art, so no beer and no
// foam.
export function beerLevelY(art: BeerMugArt, level: number): number {
  return level <= 0 ? art.h + 5 : art.bb - level * (art.bb - art.bt);
}

function foamBandHeight(art: BeerMugArt, level: number): number {
  const f = 0.5 + 0.5 * level;
  return Math.max(2, (art.bandBottom - art.bandTop) * f);
}

// THE FOAM CAP: a scalloped top edge on the band, so the surface isn't a
// straight line. Seeded from the mug and the level, so the same mug at the same
// level always looks the same. The level is taken to the nearest 2%, which also
// keeps a slow drain from boiling. One path, so a frame just sets its d. null:
// no cap (an empty mug, or one so full the art's own crown takes over).
export function beerFoamCap(id: BeerMugId, level: number): { y: number; d: string; x0: number; x1: number } | null {
  if (level <= 0 || level >= CAP_MAX_LEVEL) return null;
  const art = BEER_MUGS[id];
  const f = 0.5 + 0.5 * level;
  const y = beerLevelY(art, level) - foamBandHeight(art, level) + 1;
  const seed = [...id].reduce((h, c) => Math.imul(h, 31) + c.charCodeAt(0), 7) + Math.round(level * 50) * 7919;
  const random = beerRandom(seed);
  const parts: string[] = [];
  const last = art.glassX1 + 10;
  for (let x = art.glassX0 - 2; x <= last; ) {
    const r = (6 + 5 * random()) * (0.55 + 0.45 * f);
    parts.push(`M${round(x - r)} ${round(y)}a${round(r)} ${round(r)} 0 1 0 ${round(2 * r)} 0a${round(r)} ${round(r)} 0 1 0 ${round(-2 * r)} 0Z`);
    x += 1.25 * r;
  }
  const x0 = art.glassX0 - 4;
  const x1 = art.glassX1 + 4;
  parts.push(`M${round(x0)} ${round(y)}H${round(x1)}V${round(y + CAP_DEPTH)}H${round(x0)}Z`);
  return { y: round(y), d: parts.join(""), x0: art.glassX0 - 3, x1 };
}

// Everything that moves with the level: both clips, the cap, the band and the
// crown. What React draws at rest and what each frame of a drain sets are the
// same numbers, so a drain always lands exactly on the drawing.
export type BeerDrawing = {
  levelY: number;
  cap: { d: string; opacity: number };
  band: { y: number; height: number; opacity: number };
  crown: { y: number; opacity: number };
};

export function beerDrawing(id: BeerMugId, level: number): BeerDrawing {
  const art = BEER_MUGS[id];
  const levelY = beerLevelY(art, level);
  if (level <= 0) {
    return { levelY, cap: { d: "", opacity: 0 }, band: { y: 0, height: 0, opacity: 0 }, crown: { y: 0, opacity: 0 } };
  }
  const height = foamBandHeight(art, level);
  const opacity = round(Math.min(1, level / 0.08));
  return {
    levelY: round(levelY),
    cap: { d: beerFoamCap(id, level)?.d ?? "", opacity },
    band: { y: round(levelY - height), height: round(height), opacity },
    crown: { y: round((1 - level) * (art.bb - art.bt) * 0.5), opacity: round(clamp((level - 0.88) / 0.12, 0, 1)) },
  };
}

// A DRAIN: the same rule as The Derby's slide. Forward by up to 60 points
// tweens; backward (a New Game's reset), a longer jump or a hidden score snaps.
export const BEER_DRAIN_MS = 500;
export const BEER_MAX_DRAIN = 60;

export function beerDrains(from: number | null, to: number | null): boolean {
  if (from === null || to === null) return false;
  const start = clampScore(from);
  const end = clampScore(to);
  return end > start && end - start <= BEER_MAX_DRAIN;
}

export function beerEase(t: number): number {
  return 1 - (1 - t) ** 3;
}

// The SVG's label, since the plates' text is gone: "Walt 94, Normie 71", teams
// as "Team 1 (Walt and Buddy) 94", a hidden score as "score hidden".
export function beerAriaLabel(plates: readonly ScorePlate[]): string {
  return plates
    .map((plate, i) => {
      const names = plate.members.map((m) => m.name);
      const team = plate.key.match(/^team-(\d+)$/)?.[1] ?? String(i + 1);
      const who = names.length > 1 ? `Team ${team} (${names.join(" and ")})` : names.join(" ");
      return `${who} ${plate.scoreHidden ? "score hidden" : plate.score}`;
    })
    .join(", ");
}

// THE PROFILE'S PREVIEW: the tall strip at a phone's size, three sample
// players with no photos (the letter avatars), in the board's lane colours.
export const BEER_PREVIEW_SIZE = { w: 375, h: 117 };

export function beerPreviewPlates(skin: BoardSkin): ScorePlate[] {
  return [
    { id: "a", name: "Walt", score: 38 },
    { id: "b", name: "Normie", score: 76 },
    { id: "c", name: "Buddy", score: 104 },
  ].map(({ id, name, score }, lane) => ({
    key: id,
    members: [{ userId: id, name, avatarUrl: null }],
    score,
    isMine: false,
    hasDealer: false,
    lastPoints: null,
    lastReason: null,
    lastAwardedAt: null,
    laneColor: laneRingColor(skin, lane),
  }));
}
