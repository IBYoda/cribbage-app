// CUSTOM BOARDS: complete boards, each with its own look, as opposed to a
// pattern in a skin's colours (lib/boardSkins.ts). The Profile's "Custom"
// pattern lists them. Adding a board means adding one entry to CUSTOM_BOARDS
// (and, for new art or a new peg, one drawing in
// components/table/CribbageBoard.tsx). Display only: nothing here reaches the
// server, the scores or the other players. Pure, no React; tested by
// scripts/test-phase3.ts.

import type { BoardGeometry, BoardPattern } from "@/lib/boardLayout";
import { CLASSIC_WOOD, type BoardSkin } from "@/lib/boardSkins";

// The Pattern row's fourth tile. One line to rename it.
export const CUSTOM_PATTERN_LABEL = "Custom";

export type CustomBoard = {
  id: string;
  name: string;
  // The track it uses (lib/boardLayout.ts).
  layout: BoardPattern;
  // Its art, drawn over the skin's face.
  art: "football";
  // Its colours: the same data as any board, so the lane rings and the
  // self-scoring banner follow it.
  skin: BoardSkin;
  // pegs: how many a player shows. 1: only the front peg, at the score
  // (frontPegScore, lib/boardLayout.ts); nextPegs still runs, and its back
  // peg is ignored. shape: which peg is drawn.
  peg: { pegs: 1 | 2; shape: "round" | "football" };
};

// The field's colours. It draws no holes or lane lines (a board with `art`
// never does), so only the lanes' peg and ring colours show: Classic Pine's,
// except the fourth lane's amber, because its dark peg all but vanishes on
// green.
const FOOTBALL_FIELD: BoardSkin = {
  id: "football",
  name: "The Football",
  wood: { top: "#1f6b35", bottom: "#1a5e2e", grain: null, grainOpacity: 0 },
  rim: { edge: "#0e3a1c", highlight: "#7fc48f" },
  hole: { fill: "#eef3e6", lip: null },
  laneStyle: "paint",
  lanes: CLASSIC_WOOD.lanes,
  fourthLane: { color: "#f0b429", peg: "#f0b429", paint: "#f0b429" },
};

export const CUSTOM_BOARDS: readonly CustomBoard[] = [
  {
    id: "football",
    name: "The Football",
    layout: "straight",
    art: "football",
    skin: FOOTBALL_FIELD,
    peg: { pegs: 1, shape: "football" },
  },
];

// THE FOOTBALL FIELD, measured on the straight board's own geometry. The art
// is drawn from these and never moves a hole's position.

// The football peg's half-length and half-height, as parts of the peg radius.
// Short enough to stay on the board at the start holes.
export const FOOTBALL_PEG_RX = 1.2;
export const FOOTBALL_PEG_RY = 0.85;

// The yard numbers, on the yard lines between the goal lines.
export const YARD_NUMBERS = [10, 20, 30, 40, 50, 40, 30, 20, 10] as const;
export const YARD_NUMBER_MIN_PX = 9;
const YARD_NUMBER_MAX_PX = 13;

// The 11 lines from goal line to goal line, 10 yards apart: the first group of
// five holes is the left end zone and the last the right, and each line sits
// in the gap between two groups, so none crosses a football's path along a row
// at a hole.
export function fieldYardLines(g: BoardGeometry): number[] {
  const half = (g.pitch + g.groupGap) / 2;
  return Array.from({ length: 11 }, (_, i) => g.columnX[(i + 1) * 5] - half);
}

// The space a football never covers across the field: the band between two
// lanes, less half a football at each side. Nothing outside the lanes will do:
// the top and bottom lanes run too close to the rim, and they can't move.
function freeLaneBand(g: BoardGeometry): number {
  return g.rows[1].out - g.rows[0].back - 2 * g.pegR * FOOTBALL_PEG_RY;
}

// The yard numbers' size, or null where they'd be under YARD_NUMBER_MIN_PX
// (a short phone's strip): then the field just leaves them out.
export function yardNumberPx(g: BoardGeometry): number | null {
  const free = freeLaneBand(g);
  return free < YARD_NUMBER_MIN_PX ? null : Math.min(free, YARD_NUMBER_MAX_PX);
}

// Where they sit: centred in the first and last bands between lanes, like
// the two rows of numbers on a real field.
export function yardNumberRows(g: BoardGeometry): [number, number] {
  const last = g.rows.length - 1;
  return [(g.rows[0].back + g.rows[1].out) / 2, (g.rows[last - 1].back + g.rows[last].out) / 2];
}

// The midfield logo's font size: large on the field, and clear of the yard
// numbers when they show (a capital is about 0.75 of the font size).
export function fieldLogoPx(g: BoardGeometry): number {
  const size = g.height * 0.34;
  const numbers = yardNumberPx(g);
  if (numbers === null) return size;
  const [top, bottom] = yardNumberRows(g);
  return Math.min(size, (bottom - top - numbers - 2) / 0.75);
}

// A stored id as a board: anything unknown or missing is no custom board, so
// the player's normal board shows.
export function customBoardById(id: string | null | undefined): CustomBoard | null {
  return CUSTOM_BOARDS.find((b) => b.id === id) ?? null;
}

// THE PROFILE SETTING "Custom": which custom board THIS player sees, on this
// device only, in its own key. It never touches the saved pattern or colours
// (nobs:board-pattern, nobs:board), so leaving Custom brings them straight
// back. Guarded like them: storage can be missing or blocked.
export const CUSTOM_BOARD_KEY = "nobs:board-custom";

export function readCustomBoardId(): string | null {
  try {
    return customBoardById(localStorage.getItem(CUSTOM_BOARD_KEY))?.id ?? null;
  } catch {
    return null;
  }
}

// null: back to the normal board.
export function writeCustomBoardId(id: string | null) {
  try {
    const board = customBoardById(id);
    if (board) localStorage.setItem(CUSTOM_BOARD_KEY, board.id);
    else localStorage.removeItem(CUSTOM_BOARD_KEY);
  } catch {
    // Not saved; the board stays as it was for next time.
  }
}
