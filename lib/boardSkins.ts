// BOARD SKINS (PRD item 31): the cribbage board's look, as data, so boards
// can be added (and maybe sold -- PRD item 31, parked) without touching
// components/table/CribbageBoard.tsx. Six boards, all on the same track and
// geometry (lib/boardLayout.ts): only the wood, the lanes, the holes and the
// pegs change. Each player picks the board THEY see in Profile (device only,
// see "THE PROFILE SETTING" below); nothing is sent to the server or to the
// other players. Pure, no React; tested by scripts/test-phase3.ts.
//
// All our own art: the board is drawn in code from these colours (SVG
// gradients and patterns), never from an image. Every skin works on both
// patterns (Straight and S: lib/boardLayout.ts).

import type { BoardPattern } from "@/lib/boardLayout";

export type LaneSkin = {
  // The lane's colour: its panel (or outline, or painted line) and the
  // ring round its player's avatar.
  color: string;
  // The peg's colour (the board draws the rest of the peg: see pegShades).
  peg: string;
  // "paint" lanes only: the painted line, if not the lane colour.
  paint?: string;
};

// How a lane is drawn:
//   * paint: a painted line between its two rows, on the wood (Classic Pine);
//   * fill: a panel in the lane colour, round both rows;
//   * outline: a dark panel (BoardSkin.panel) with a thin lane-coloured edge;
//   * metal: a brushed-metal panel in the lane colour.
export type LaneStyle = "paint" | "fill" | "outline" | "metal";

export type BoardSkin = {
  id: string;
  name: string;
  wood: {
    // The board's face, top to bottom.
    top: string;
    bottom: string;
    // The grain lines over it (null: none).
    grain: string | null;
    grainOpacity: number;
  };
  // "brushed-steel": fine horizontal brushed lines over the face and one
  // soft diagonal specular streak.
  finish?: "brushed-steel";
  rim: {
    // The board's outer edge, and the lit inner edge of the rim (a bevel).
    edge: string;
    highlight: string;
    // A chrome rim instead: a 5px band in this diagonal gradient.
    chrome?: readonly string[];
  };
  hole: {
    // A drilled hole: dark inside, and a lighter lip (or none).
    fill: string;
    lip: string | null;
    // A thin stroke round each hole in its lane's colour.
    laneStroke?: boolean;
  };
  laneStyle: LaneStyle;
  // "outline" lanes: the panel's fill.
  panel?: string;
  // Lane 0 (the first seat), 1, 2.
  lanes: readonly [LaneSkin, LaneSkin, LaneSkin];
  // What a player would need to unlock this board (BoardUnlock), for when
  // boards can be locked. Not read anywhere yet: every board is selectable.
  // Absent: always free.
  unlock?: BoardUnlock;
};

// A requirement to unlock a board, as plain data (no functions), so it can
// sit in the skin list and later be checked on the server. Not read yet.
//   * wins: win this many (counted) games;
//   * beat-computer: beat this computer level;
//   * purchase: owned through this product id (PRD item 31, parked).
export type BoardUnlock =
  | { kind: "wins"; count: number }
  | { kind: "beat-computer"; level: "easy" | "medium" | "hard" }
  | { kind: "purchase"; productId: string };

// COLOUR HELPERS (pure; also used by the board to shade its pegs and lanes).
type Rgb = readonly [number, number, number];

export function isHexColor(value: string): boolean {
  return /^#[0-9a-f]{6}$/i.test(value);
}

function rgbOf(hex: string): Rgb {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function hexOf([r, g, b]: Rgb): string {
  return `#${[r, g, b].map((v) => Math.round(Math.min(Math.max(v, 0), 255)).toString(16).padStart(2, "0")).join("")}`;
}

// `hex` moved toward `target` by t (0 .. 1).
export function mixHex(hex: string, target: string, t: number): string {
  const a = rgbOf(hex);
  const b = rgbOf(target);
  return hexOf([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]);
}

export const lighten = (hex: string, t: number) => mixHex(hex, "#ffffff", t);
export const darken = (hex: string, t: number) => mixHex(hex, "#000000", t);

// WCAG relative luminance and contrast ratio (1 .. 21).
export function luminance(hex: string): number {
  const [r, g, b] = rgbOf(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// How different two colours look: the CIE76 distance in Lab (D65). About 2
// is the smallest difference anyone notices; 20+ reads as a different colour.
export function colorDistance(a: string, b: string): number {
  const lab = (hex: string) => {
    const [r, g, b2] = rgbOf(hex).map((v) => {
      const c = v / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    const x = (0.4124 * r + 0.3576 * g + 0.1805 * b2) / 0.95047;
    const y = 0.2126 * r + 0.7152 * g + 0.0722 * b2;
    const z = (0.0193 * r + 0.1192 * g + 0.9505 * b2) / 1.08883;
    const f = (t: number) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
  };
  const [l1, a1, b1] = lab(a);
  const [l2, a2, b2] = lab(b);
  return Math.hypot(l1 - l2, a1 - a2, b1 - b2);
}

// THE SKINS.

// The cheap wooden 3-lane board everyone buys: light pine, red, blue and
// green painted lanes. Its pegs are in the lane colours -- the one board
// below the peg-contrast floor (pegContrast): a red peg sits on a red line,
// and it relies on the peg's dark outline to read.
export const CLASSIC_WOOD: BoardSkin = {
  id: "classic-wood",
  name: "Classic Pine",
  wood: { top: "#d9a86a", bottom: "#b57a40", grain: "#7a4a1f", grainOpacity: 0.28 },
  rim: { edge: "#5e3a17", highlight: "#f1cf9a" },
  hole: { fill: "#2a1708", lip: "#e9c48f" },
  laneStyle: "paint",
  lanes: [
    { color: "#d32f2f", peg: "#d32f2f", paint: "#b3261e" },
    { color: "#1e63d6", peg: "#1e63d6", paint: "#1f4fa3" },
    { color: "#2e9b4b", peg: "#2e9b4b", paint: "#23733a" },
  ],
};

// Near-black, with outlined lanes in white, gold and ice blue.
export const MIDNIGHT: BoardSkin = {
  id: "midnight",
  name: "Midnight",
  wood: { top: "#1a1a1f", bottom: "#0c0c0e", grain: null, grainOpacity: 0 },
  rim: { edge: "#34343c", highlight: "#5a5a66" },
  hole: { fill: "#050506", lip: null, laneStroke: true },
  laneStyle: "outline",
  panel: "#1d1d23",
  lanes: [
    { color: "#f2f2f2", peg: "#ffffff" },
    { color: "#e0b443", peg: "#e0b443" },
    { color: "#6cc4ff", peg: "#6cc4ff" },
  ],
};

// Dark coffee wood, bright red, green and blue lanes; silver, black and
// brass pegs.
export const ESPRESSO: BoardSkin = {
  id: "espresso",
  name: "Espresso",
  wood: { top: "#3d2419", bottom: "#24140d", grain: "#0f0805", grainOpacity: 0.22 },
  rim: { edge: "#120905", highlight: lighten("#3d2419", 0.3) },
  hole: { fill: "#0d0705", lip: null },
  laneStyle: "fill",
  lanes: [
    { color: "#e5413b", peg: "#e9edf2" },
    { color: "#34b857", peg: "#17110e" },
    { color: "#3578ec", peg: "#f2cf63" },
  ],
};

// Red mahogany, red, white and blue lanes; silver, black and gold pegs.
export const MAHOGANY: BoardSkin = {
  id: "mahogany",
  name: "Mahogany",
  wood: { top: "#6d2323", bottom: "#4a1414", grain: "#200606", grainOpacity: 0.22 },
  rim: { edge: "#2a0b0b", highlight: lighten("#6d2323", 0.3) },
  hole: { fill: "#1b0808", lip: null },
  laneStyle: "fill",
  lanes: [
    { color: "#d8302f", peg: "#d9dde2" },
    { color: "#f4f1ea", peg: "#1b1b1f" },
    { color: "#2c63c8", peg: "#f6d57a" },
  ],
};

// Old walnut in quiet browns: brown, tan and ivory lanes; cream, dark and
// copper pegs.
export const HERITAGE: BoardSkin = {
  id: "heritage",
  name: "Heritage",
  wood: { top: "#4a2a20", bottom: "#331b14", grain: "#140905", grainOpacity: 0.22 },
  rim: { edge: "#1f0f0a", highlight: lighten("#4a2a20", 0.3) },
  hole: { fill: "#2a1710", lip: null },
  laneStyle: "fill",
  lanes: [
    { color: "#8c5a44", peg: "#f3e3c3" },
    { color: "#c8a47c", peg: "#2c1d17" },
    { color: "#efe6d4", peg: "#a8622f" },
  ],
};

// Black brushed steel in a chrome rim; bronze, gold and silver brushed-metal
// lanes; chrome, gunmetal and bronze pegs.
export const METALLIC: BoardSkin = {
  id: "metallic",
  name: "Metallic",
  wood: { top: "#2d3139", bottom: "#101216", grain: null, grainOpacity: 0 },
  finish: "brushed-steel",
  rim: {
    edge: "#626874",
    highlight: "#f1f3f6",
    chrome: ["#f1f3f6", "#7d8490", "#d7dbe1", "#626874", "#e3e6eb"],
  },
  hole: { fill: "#0b0d10", lip: null },
  laneStyle: "metal",
  lanes: [
    { color: "#b9733a", peg: "#f5f7fa" },
    { color: "#d9b44c", peg: "#2b3038" },
    { color: "#c9cdd3", peg: "#a85a26" },
  ],
};

// In the Profile picker's order.
export const BOARD_SKIN_LIST: readonly BoardSkin[] = [CLASSIC_WOOD, MIDNIGHT, ESPRESSO, MAHOGANY, HERITAGE, METALLIC];

export const BOARD_SKINS: Record<string, BoardSkin> = Object.fromEntries(BOARD_SKIN_LIST.map((s) => [s.id, s]));

export const DEFAULT_BOARD_SKIN = CLASSIC_WOOD;

// A stored or passed id as a skin: anything unknown or missing is Classic Pine.
export function boardSkinById(id: string | null | undefined): BoardSkin {
  return (id && Object.prototype.hasOwnProperty.call(BOARD_SKINS, id) && BOARD_SKINS[id]) || DEFAULT_BOARD_SKIN;
}

// THE LOOK, FROM THE DATA.

// The ring round a player's avatar: their lane's colour.
export function laneRingColor(skin: BoardSkin, lane: number): string {
  return skin.lanes[lane].color;
}

// What a lane's pegs and holes sit on: the panel for an outline lane, the
// lane colour for a filled or metal one (its base), the lane colour for a
// painted line too (the peg sits on the line).
export function laneSurface(skin: BoardSkin, lane: number): string {
  return skin.laneStyle === "outline" && skin.panel ? skin.panel : skin.lanes[lane].color;
}

// THE S BOARD's ribbon for a lane (components/table/CribbageBoard.tsx draws
// it with this): what its pegs and holes sit on -- the same surface as the
// straight board's lane, so the contrast floors hold on both patterns. A
// painted lane (Classic Pine) is a thin painted line along its holes.
export function sRibbonFill(skin: BoardSkin, lane: number): string {
  return skin.laneStyle === "paint" ? (skin.lanes[lane].paint ?? skin.lanes[lane].color) : laneSurface(skin, lane);
}

// The S board's score plates (on the middle lane): a white oval with dark
// numbers, or a dark one with light numbers on the outline board (Midnight).
// Where the oval is too close in colour to its ribbon to show -- white on
// Mahogany's white lane, dark on Midnight's dark panel -- it gets a thin edge:
// the lane's colour on the outline board, else a darker shade of the ribbon.
export function sPlateColors(skin: BoardSkin): { fill: string; text: string; edge: string | null } {
  const plate = skin.laneStyle === "outline" ? { fill: "#2a2a32", text: "#f2f2f2" } : { fill: "#f5f1e6", text: "#2a1c12" };
  const ribbon = sRibbonFill(skin, 1);
  const edge =
    contrastRatio(plate.fill, ribbon) >= 1.5
      ? null
      : skin.laneStyle === "outline"
        ? skin.lanes[1].color
        : darken(ribbon, 0.5);
  return { ...plate, edge };
}

// A peg's round body: a radial gradient from a highlight (at 36% / 30% of
// the peg) through its colour to a dark edge.
export function pegShades(peg: string): { light: string; base: string; dark: string } {
  return { light: lighten(peg, 0.8), base: peg, dark: darken(peg, 0.5) };
}

// A metal lane's vertical gradient, top to bottom: [offset %, colour].
export function metalLaneStops(color: string): readonly (readonly [number, string])[] {
  return [
    [0, lighten(color, 0.35)],
    [20, lighten(color, 0.68)],
    [42, color],
    [72, darken(color, 0.36)],
    [88, darken(color, 0.12)],
    [100, lighten(color, 0.22)],
  ];
}

// THE CONTRAST FLOORS (tested for every skin but Classic Pine).
export const PEG_CONTRAST_MIN = 2.5;
export const HOLE_CONTRAST_MIN = 2.9;
export const LANE_DISTANCE_MIN = 20;

// A lane's peg against what it sits on (laneSurface).
export function pegContrast(skin: BoardSkin, lane: number): number {
  return contrastRatio(skin.lanes[lane].peg, laneSurface(skin, lane));
}

// Classic Pine's pegs are its lane colours, on lines of the same colour: the
// one board allowed below the peg floor (its pegs rely on their outline).
export function pegContrastExempt(skin: BoardSkin): boolean {
  return skin.id === CLASSIC_WOOD.id;
}

// A lane's holes against its colour. Exempt: outline lanes (each hole has a
// lane-coloured edge) and painted lanes (the holes are on the wood).
export function holeContrast(skin: BoardSkin, lane: number): number {
  return contrastRatio(skin.hole.fill, skin.lanes[lane].color);
}

export function holeContrastExempt(skin: BoardSkin): boolean {
  return skin.laneStyle === "outline" || skin.laneStyle === "paint";
}

// The closest two of a skin's three lane colours (colorDistance).
export function laneSeparation(skin: BoardSkin): number {
  const [a, b, c] = skin.lanes.map((l) => l.color);
  return Math.min(colorDistance(a, b), colorDistance(a, c), colorDistance(b, c));
}

// THE SELF-SCORING BANNER's text (it sits in the board strip, in the board's
// colours): the rim colour if it reads better on the board's face than a
// light cream, else the cream. Classic Pine keeps its rim-coloured text.
export function bannerTextColor(skin: BoardSkin): string {
  const cream = "#f5efe3";
  const worst = (c: string) => Math.min(contrastRatio(c, skin.wood.top), contrastRatio(c, skin.wood.bottom));
  return worst(skin.rim.edge) >= worst(cream) ? skin.rim.edge : cream;
}

// THE PROFILE SETTING "Board": which board THIS player sees on the square
// table, on this device only (localStorage, no account column). Every read
// and write is guarded -- storage can be missing or blocked (a private
// window, a preview) -- and never throws; anything unknown reads as
// Classic Pine.
export const BOARD_SETTING_KEY = "nobs:board";

export function readBoardSkinId(): string {
  try {
    return boardSkinById(localStorage.getItem(BOARD_SETTING_KEY)).id;
  } catch {
    return DEFAULT_BOARD_SKIN.id;
  }
}

export function writeBoardSkinId(id: string) {
  try {
    const skin = boardSkinById(id);
    if (skin.id === DEFAULT_BOARD_SKIN.id) localStorage.removeItem(BOARD_SETTING_KEY);
    else localStorage.setItem(BOARD_SETTING_KEY, skin.id);
  } catch {
    // Not saved; the board stays as it was for next time.
  }
}

// THE PROFILE SETTING "Pattern": the board's shape (lib/boardLayout.ts),
// beside its colours -- this device only, guarded the same way. Anything but
// "s" reads as Straight.
export const BOARD_PATTERN_KEY = "nobs:board-pattern";

export const DEFAULT_BOARD_PATTERN: BoardPattern = "straight";

export function boardPatternById(id: string | null | undefined): BoardPattern {
  return id === "s" ? "s" : DEFAULT_BOARD_PATTERN;
}

export function readBoardPattern(): BoardPattern {
  try {
    return boardPatternById(localStorage.getItem(BOARD_PATTERN_KEY));
  } catch {
    return DEFAULT_BOARD_PATTERN;
  }
}

export function writeBoardPattern(pattern: string) {
  try {
    const p = boardPatternById(pattern);
    if (p === DEFAULT_BOARD_PATTERN) localStorage.removeItem(BOARD_PATTERN_KEY);
    else localStorage.setItem(BOARD_PATTERN_KEY, p);
  } catch {
    // Not saved; the pattern stays as it was for next time.
  }
}
